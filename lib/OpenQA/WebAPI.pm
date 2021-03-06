# Copyright (C) 2015-2016 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebAPI;
use strict;
use Mojolicious 5.60;
use Mojo::Base 'Mojolicious';
use OpenQA::Schema;
use OpenQA::WebAPI::Plugin::Helpers;
use OpenQA::IPC;
use OpenQA::Worker::Common qw/ASSET_DIR/;
use OpenQA::Utils qw/log_warning/;

use Mojo::IOLoop;
use Mojolicious::Commands;
use DateTime;
use Cwd qw/abs_path/;
use File::Path qw/make_path/;

use Config::IniFiles;
use db_profiler;
use db_helpers;

sub _read_config {
    my $self = shift;

    my %defaults = (
        global => {
            appname          => 'openQA',
            base_url         => undef,
            branding         => 'openSUSE',
            allowed_hosts    => undef,
            download_domains => undef,
            suse_mirror      => undef,
            scm              => undef,
            hsts             => 365,
            audit_enabled    => 1,
            plugins          => undef,
            hide_asset_types => 'repo',
        },
        auth => {
            method => 'OpenID',
        },
        'scm git' => {
            do_push => 'no',
        },
        logging => {
            level     => undef,
            file      => undef,
            sql_debug => undef,
        },
        openid => {
            provider  => 'https://www.opensuse.org/openid/user/',
            httpsonly => 1,
        },
        hypnotoad => {
            listen => ['http://localhost:9526/'],
            proxy  => 1,
        },
        audit => {
            blacklist => '',
        },
    );

    # in development mode we use fake auth and log to stderr
    my %mode_defaults = (
        development => {
            auth => {
                method => 'Fake',
            },
            logging => {
                file  => undef,
                level => 'debug',
            },
        },
        test => {
            auth => {
                method => 'Fake',
            },
            logging => {
                file  => undef,
                level => 'debug',
            },
        });

    # Mojo's built in config plugins suck. JSON for example does not
    # support comments
    my $cfgpath = $ENV{OPENQA_CONFIG} || $self->app->home . '/etc/openqa';
    my $cfg = Config::IniFiles->new(-file => $cfgpath . '/openqa.ini') || undef;

    for my $section (sort keys %defaults) {
        for my $k (sort keys %{$defaults{$section}}) {
            my $v = $cfg && $cfg->val($section, $k);
            $v //= exists $mode_defaults{$self->mode}{$section}->{$k} ? $mode_defaults{$self->mode}{$section}->{$k} : $defaults{$section}->{$k};
            $self->app->config->{$section}->{$k} = $v if defined $v;
        }
    }
    $self->app->config->{_openid_secret} = db_helpers::rndstr(16);
}

sub _get_dead_worker_jobs {
    my ($self, $threshold) = @_;

    my %cond = (
        state              => OpenQA::Schema::Result::Jobs::RUNNING,
        'worker.t_updated' => {'<' => $threshold},
    );
    my %attrs = (join => 'worker',);

    return $self->app->db->resultset("Jobs")->search(\%cond, \%attrs);
}

# check if have worker dead then clean up its job
# TODO: this really should live in websockets service, not in webapi
sub _workers_checker {
    my ($self) = @_;

    # Start recurring timer, check workers alive every 20 mins
    my $id = Mojo::IOLoop->recurring(
        1200 => sub {
            my $dt = DateTime->now(time_zone => 'UTC');
            my $threshold = join ' ', $dt->ymd, $dt->hms;

            Mojo::IOLoop->timer(
                10 => sub {
                    my $dead_jobs = $self->_get_dead_worker_jobs($threshold);
                    my $ipc       = OpenQA::IPC->ipc;
                    for my $job ($dead_jobs->all) {
                        my %args = (
                            jobid  => $job->id,
                            result => 'incomplete',
                        );
                        my $result = $ipc->scheduler('job_set_done', \%args);
                        if ($result) {
                            $ipc->scheduler('job_duplicate', {jobid => $job->id});
                            $self->app->log->error(sprintf("cancelled dead job %d and re-duplicated done", $job->id));
                        }
                    }
                });
        });
}

# reinit pseudo random number generator in every child to avoid
# starting off with the same state.
sub _init_rand {
    my $self = shift;
    return unless $ENV{HYPNOTOAD_APP};
    Mojo::IOLoop->timer(
        0 => sub {
            srand;
            $self->app->log->debug("initialized random number generator in $$");
        });
}

has schema => sub {
    return OpenQA::Schema::connect_db();
};

has secrets => sub {
    my $self = shift;
    # read application secret from database
    # we cannot use our own schema here as we must not actually
    # initialize the db connection here. Would break for prefork.
    my @secrets = $self->schema->resultset('Secrets')->all();
    if (!@secrets) {
        # create one if it doesn't exist
        $self->schema->resultset('Secrets')->create({});
        @secrets = $self->schema->resultset('Secrets')->all();
    }
    die "couldn't create secrets\n" unless @secrets;
    my $ret = [map { $_->secret } @secrets];
    return $ret;
};

sub _log_format {
    my ($time, $level, @lines) = @_;
    return '[' . localtime($time) . "] [$$:$level] " . join "\n", @lines, '';
}

# This method will run once at server start
sub startup {
    my $self = shift;

    $self->_read_config;

    # Set some application defaults
    $self->defaults(appname => $self->app->config->{global}->{appname});

    my $logfile = $ENV{OPENQA_LOGFILE} || $self->config->{logging}->{file};
    $self->log->path($logfile);
    $self->log->format(\&_log_format);

    if ($logfile && $self->config->{logging}->{level}) {
        $self->log->level($self->config->{logging}->{level});
    }
    if ($ENV{OPENQA_SQL_DEBUG} // $self->config->{logging}->{sql_debug} // 'false' eq 'true') {
        # avoid enabling the SQL debug unless we really want to see it
        # it's rather expensive
        db_profiler::enable_sql_debugging($self);
    }

    unless ($ENV{MOJO_TMPDIR}) {
        $ENV{MOJO_TMPDIR} = ASSET_DIR . '/tmp';
        # Try to create tmpdir if it doesn't exist but don't die if failed to create
        if (!-e $ENV{MOJO_TMPDIR}) {
            eval { make_path($ENV{MOJO_TMPDIR}); };
            if ($@) {
                print STDERR "Can not create MOJO_TMPDIR : $@\n";
            }
        }
        delete $ENV{MOJO_TMPDIR} unless -w $ENV{MOJO_TMPDIR};
    }

    # take care of DB deployment or migration before starting the main app
    my $schema = OpenQA::Schema::connect_db;
    OpenQA::Schema::deployment_check($schema);

    unshift @{$self->renderer->paths}, '/etc/openqa/templates';

    $self->plugin(AssetPack => {pipes => [qw(Sass Css JavaScript Fetch OpenQA::WebAPI::AssetPipe Combine)]});
    $self->plugin('OpenQA::WebAPI::Plugin::Helpers');
    $self->plugin('OpenQA::WebAPI::Plugin::CSRF');
    $self->plugin('OpenQA::WebAPI::Plugin::REST');
    $self->plugin('OpenQA::WebAPI::Plugin::HashedParams');
    $self->plugin('OpenQA::WebAPI::Plugin::Gru');
    if ($self->config->{global}{audit_enabled}) {
        $self->plugin('OpenQA::WebAPI::Plugin::AuditLog', Mojo::IOLoop->singleton);
    }
    # Load arbitrary plugins defined in config: 'plugins' in section
    # '[global]' can be a space-separated list of plugins to load, by
    # module name under OpenQA::WebAPI::Plugin::
    if (defined $self->config->{global}->{plugins}) {
        my @plugins = split(' ', $self->config->{global}->{plugins});
        for my $plugin (@plugins) {
            $self->log->info("Loading external plugin $plugin");
            $self->plugin("OpenQA::WebAPI::Plugin::$plugin");
        }
    }

    # read assets/assetpack.def
    $self->asset->process;

    # set secure flag on cookies of https connections
    $self->hook(
        before_dispatch => sub {
            my $c = shift;
            #$c->app->log->debug(sprintf "this connection is %ssecure", $c->req->is_secure?'':'NOT ');
            if ($c->req->is_secure) {
                $c->app->sessions->secure(1);
            }
            if (my $days = $c->app->config->{global}->{hsts}) {
                $c->res->headers->header('Strict-Transport-Security', sprintf 'max-age=%d; includeSubDomains', $days * 24 * 60 * 60);
            }
        });

    $OpenQA::Utils::app = $self;

    # load auth module
    my $auth_method = $self->config->{auth}->{method};
    my $auth_module = "OpenQA::WebAPI::Auth::$auth_method";
    eval "require $auth_module";    ## no critic
    if ($@) {
        die sprintf('Unable to load auth module %s for method %s', $auth_module, $auth_method);
    }
    $auth_module->import('auth_config');
    auth_config($self->config);

    # Router
    my $r         = $self->routes;
    my $logged_in = $r->under('/')->to("session#ensure_user");
    my $auth      = $r->under('/')->to("session#ensure_operator");

    $r->post('/session')->to('session#create');
    $r->delete('/session')->to('session#destroy');
    $r->get('/login')->name('login')->to('session#create');
    $r->post('/login')->to('session#create');
    $r->delete('/logout')->name('logout')->to('session#destroy');
    $r->get('/response')->to('session#response');
    $auth->get('/session/test')->to('session#test');

    my $apik_auth = $auth->route('/api_keys');
    $apik_auth->get('/')->name('api_keys')->to('api_key#index');
    $apik_auth->post('/')->to('api_key#create');
    $apik_auth->delete('/:apikeyid')->name('api_key')->to('api_key#destroy');

    $r->get('/tests')->name('tests')->to('test#list');
    $r->get('/tests/overview')->name('tests_overview')->to('test#overview');
    $r->get('/tests/export')->name('tests_export')->to('test#export');
    $r->post('/tests/list_ajax')->name('tests_ajax')->to('test#list_ajax');
    my $test_r = $r->route('/tests/:testid', testid => qr/\d+/);
    my $test_auth = $auth->route('/tests/:testid', testid => qr/\d+/, format => 0);
    $test_r->get('/')->name('test')->to('test#show');
    my $test_logged_in = $logged_in->route('/tests/:testid', testid => qr/\d+/);
    $test_logged_in->post('/add_comment')->name('add_comment')->to('test#add_comment');
    $test_logged_in->post('/edit_comment')->name('edit_comment')->to('test#edit_comment');
    $test_logged_in->post('/remove_comment')->name('remove_comment')->to('test#remove_comment');

    $test_r->get('/modlist')->name('modlist')->to('running#modlist');
    $test_r->get('/status')->name('status')->to('running#status');
    $test_r->get('/livelog')->name('livelog')->to('running#livelog');
    $test_r->get('/streaming')->name('streaming')->to('running#streaming');
    $test_r->get('/edit')->name('edit_test')->to('running#edit');

    my $log_auth = $r->under('/tests/#testid')->to("session#ensure_authorized_ip");

    $test_r->get('/images/#filename')->name('test_img')->to('file#test_file');
    $test_r->get('/images/thumb/#filename')->name('test_thumbnail')->to('file#test_thumbnail');
    $test_r->get('/file/#filename')->name('test_file')->to('file#test_file');
    $test_r->get('/iso')->name('isoimage')->to('file#test_isoimage');
    # adding assetid => qr/\d+/ doesn't work here. wtf?
    $test_r->get('/asset/#assetid')->name('test_asset_id')->to('file#test_asset');
    $test_r->get('/asset/#assettype/#assetname')->name('test_asset_name')->to('file#test_asset');
    $test_r->get('/asset/#assettype/#assetname/*subpath')->name('test_asset_name_path')->to('file#test_asset');

    my $step_r = $test_r->route('/modules/:moduleid/steps/:stepid', stepid => qr/[1-9]\d*/)->to(controller => 'step');
    my $step_auth = $test_auth->route('/modules/:moduleid/steps/:stepid', stepid => qr/[1-9]\d*/);
    $step_r->get('/view')->to(action => 'view');
    $step_r->get('/edit')->name('edit_step')->to(action => 'edit');
    $step_r->get('/src')->name('src_step')->to(action => 'src');
    $step_auth->post('/')->name('save_needle_ajax')->to('step#save_needle_ajax');
    $step_r->get('/')->name('step')->to(action => 'view');

    $r->get('/needles/:distri/#name')->name('needle_file')->to('file#needle');
    $r->get('/image/:md5_dirname/.thumbs/#md5_basename')->name('thumb_image')->to('file#thumb_image');

    $r->get('/group_overview/:groupid')->name('group_overview')->to('main#group_overview');
    $logged_in->post('/group_overview/:groupid/add_comment')->name('add_group_comment')->to('main#add_comment');
    $logged_in->post('/group_overview/:groupid/edit_comment')->name('edit_group_comment')->to('main#edit_comment');
    $logged_in->post('/group_overview/:groupid/remove_comment')->name('remove_group_comment')->to('main#remove_comment');

    # Favicon
    $r->get('/favicon.ico' => sub { my $c = shift; $c->render_static('favicon.ico') });
    # Default route
    $r->get('/')->name('index')->to('main#index');

    # Redirection for old links to openQAv1
    $r->get(
        '/results' => sub {
            my $c = shift;
            $c->redirect_to('tests');
        });

    #
    ## Admin area starts here
    ###
    my $admin_auth = $r->under('/admin')->to('session#ensure_admin');
    my $admin_r    = $admin_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::Admin');
    my $op_auth    = $r->under('/admin')->to('session#ensure_operator');
    my $op_r       = $op_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::Admin');

    # operators accessible tables
    $op_r->get('/products')->name('admin_products')->to('product#index');
    $op_r->get('/machines')->name('admin_machines')->to('machine#index');
    $op_r->get('/test_suites')->name('admin_test_suites')->to('test_suite#index');

    $op_r->get('/job_templates/:groupid')->name('admin_job_templates')->to('job_template#index');

    $op_r->get('/groups')->name('admin_groups')->to('job_group#index');
    $op_r->get('/groups/connect/:groupid')->name('job_group_new_media')->to('job_group#connect');

    $op_r->get('/assets')->name('admin_assets')->to('asset#index');

    $op_r->get('/workers')->name('admin_workers')->to('workers#index');
    $op_r->get('/workers/:worker_id')->name('admin_worker_show')->to('workers#show');

    $op_r->get('/productlog')->name('admin_product_log')->to('audit_log#productlog');

    # admins accessible tables
    $admin_r->get('/users')->name('admin_users')->to('user#index');
    $admin_r->post('/users/:userid')->name('admin_user')->to('user#update');
    $admin_r->get('/needles')->name('admin_needles')->to('needle#index');
    $admin_r->get('/needles/:module_id/:needle_id')->name('admin_needle_module')->to('needle#module');
    $admin_r->get('/needles/ajax')->name('admin_needle_ajax')->to('needle#ajax');
    $admin_r->delete('/needles/delete')->name('admin_needle_delete')->to('needle#delete');
    $admin_r->get('/auditlog')->name('audit_log')->to('audit_log#index');
    $admin_r->get('/auditlog/ajax')->name('audit_ajax')->to('audit_log#ajax');
    $admin_r->post('/groups')->name('admin_new_group')->to('job_group#create');
    $admin_r->post('/groups/connect/:groupid')->name('job_group_save_media')->to('job_group#save_connect');

    # Workers list as default option
    $op_r->get('/')->name('admin')->to('workers#index');
    ###
    ## Admin area ends here
    #

    #
    ## JSON API starts here
    ###
    my $api_auth  = $r->under('/api/v1')->to(controller => 'API::V1', action => 'auth');
    my $api_admin = $r->under('/api/v1')->to(controller => 'API::V1', action => 'auth_admin');
    my $api_r = $api_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    my $api_ra = $api_admin->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    my $api_public_r = $r->route('/api/v1')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    # this is fallback redirect if one does not use apache
    $api_public_r->websocket(
        '/ws/:workerid' => sub {
            my $c        = shift;
            my $workerid = $c->param('workerid');
            # use port one higher than WebAPI
            my $port = 9527;
            if ($ENV{MOJO_LISTEN} =~ /.*:(\d{1,5})\/?$/) {
                $port = $1 + 1;
            }
            $c->redirect_to("http://localhost:$port/ws/$workerid");
        });
    my $api_job_auth = $r->under('/api/v1')->to(controller => 'API::V1', action => 'auth_jobtoken');
    my $api_r_job = $api_job_auth->route('/')->to(namespace => 'OpenQA::WebAPI::Controller::API::V1');
    $api_r_job->get('/whoami')->name('apiv1_jobauth_whoami')->to('job#whoami');    # primarily for tests

    # api/v1/jobs
    $api_public_r->get('/jobs')->name('apiv1_jobs')->to('job#list');
    $api_r->post('/jobs')->name('apiv1_create_job')->to('job#create');             # job_create
    $api_r->post('/jobs/cancel')->name('apiv1_cancel_jobs')->to('job#cancel');
    $api_r->post('/jobs/restart')->name('apiv1_restart_jobs')->to('job#restart');

    my $job_r = $api_r->route('/jobs/:jobid', jobid => qr/\d+/);
    $api_public_r->route('/jobs/:jobid', jobid => qr/\d+/)->get('/')->name('apiv1_job')->to('job#show');
    $job_r->delete('/')->name('apiv1_delete_job')->to('job#destroy');              # job_delete
    $job_r->post('/prio')->name('apiv1_job_prio')->to('job#prio');
    # NO LONGER USED
    $job_r->post('/result')->name('apiv1_job_result')->to('job#result');           # job_update_result
    $job_r->post('/set_done')->name('apiv1_set_done')->to('job#done');             # job_set_done
    $job_r->post('/status')->name('apiv1_update_status')->to('job#update_status');
    $job_r->post('/artefact')->name('apiv1_create_artefact')->to('job#create_artefact');

    # job_set_waiting, job_set_continue
    my $command_r = $job_r->route('/set_:command', command => [qw(waiting running)]);
    $command_r->post('/')->name('apiv1_set_command')->to('job#set_command');
    $job_r->post('/restart')->name('apiv1_restart')->to('job#restart');            # job_restart
    $job_r->post('/cancel')->name('apiv1_cancel')->to('job#cancel');               # job_cancel
    $job_r->post('/duplicate')->name('apiv1_duplicate')->to('job#duplicate');      # job_duplicate

    # api/v1/workers
    $api_public_r->get('/workers')->name('apiv1_workers')->to('worker#list');
    $api_r->post('/workers')->name('apiv1_create_worker')->to('worker#create');
    my $worker_r = $api_r->route('/workers/:workerid', workerid => qr/\d+/);
    $api_public_r->route('/workers/:workerid', workerid => qr/\d+/)->get('/')->name('apiv1_worker')->to('worker#show');
    $worker_r->post('/commands/')->name('apiv1_create_command')->to('command#create');    #command_enqueue
    $worker_r->post('/grab_job')->name('apiv1_grab_job')->to('job#grab');                 # job_grab
                                                                                          # redirect for older workers
    $worker_r->websocket(
        '/ws' => sub {
            my $c        = shift;
            my $workerid = $c->param('workerid');
            # use port one higher than WebAPI
            my $port = 9527;
            if (defined $ENV{MOJO_LISTEN} && $ENV{MOJO_LISTEN} =~ /.*:(\d{1,5})\/?$/) {
                $port = $1 + 1;
            }
            $c->redirect_to("http://localhost:$port/ws/$workerid");
        });

    # api/v1/mutex
    $api_r_job->post('/mutex')->name('apiv1_mutex_create')->to('locks#mutex_create');
    $api_r_job->post('/mutex/:name')->name('apiv1_mutex_action')->to('locks#mutex_action');

    # api/v1/mm
    my $mm_api = $api_r_job->route('/mm');
    $mm_api->get('/children/:status' => [status => [qw/running scheduled done/]])->name('apiv1_mm_running_children')->to('mm#get_children_status');
    $mm_api->get('/children')->name('apiv1_mm_children')->to('mm#get_children');
    $mm_api->get('/parents')->name('apiv1_mm_parents')->to('mm#get_parents');

    # api/v1/isos
    $api_r->post('/isos')->name('apiv1_create_iso')->to('iso#create');                 # iso_new
    $api_ra->delete('/isos/#name')->name('apiv1_destroy_iso')->to('iso#destroy');      # iso_delete
    $api_r->post('/isos/#name/cancel')->name('apiv1_cancel_iso')->to('iso#cancel');    # iso_cancel

    # api/v1/assets
    $api_r->post('/assets')->name('apiv1_post_asset')->to('asset#register');
    $api_public_r->get('/assets')->name('apiv1_get_asset')->to('asset#list');
    $api_public_r->get('/assets/#id')->name('apiv1_get_asset_id')->to('asset#get');
    $api_public_r->get('/assets/#type/#name')->name('apiv1_get_asset_name')->to('asset#get');
    $api_ra->delete('/assets/#id')->name('apiv1_delete_asset')->to('asset#delete');
    $api_ra->delete('/assets/#type/#name')->name('apiv1_delete_asset_name')->to('asset#delete');

    # api/v1/test_suites
    $api_r->get('test_suites')->name('apiv1_test_suites')->to('table#list', table => 'TestSuites');
    $api_ra->post('test_suites')->to('table#create', table => 'TestSuites');
    $api_r->get('test_suites/:id')->name('apiv1_test_suite')->to('table#list', table => 'TestSuites');
    $api_ra->put('test_suites/:id')->to('table#update', table => 'TestSuites');
    $api_ra->post('test_suites/:id')->to('table#update', table => 'TestSuites');    #in case PUT is not supported
    $api_ra->delete('test_suites/:id')->to('table#destroy', table => 'TestSuites');

    # api/v1/machines
    $api_r->get('machines')->name('apiv1_machines')->to('table#list', table => 'Machines');
    $api_ra->post('machines')->to('table#create', table => 'Machines');
    $api_r->get('machines/:id')->name('apiv1_machine')->to('table#list', table => 'Machines');
    $api_ra->put('machines/:id')->to('table#update', table => 'Machines');
    $api_ra->post('machines/:id')->to('table#update', table => 'Machines');         #in case PUT is not supported
    $api_ra->delete('machines/:id')->to('table#destroy', table => 'Machines');

    # api/v1/products
    $api_r->get('products')->name('apiv1_products')->to('table#list', table => 'Products');
    $api_ra->post('products')->to('table#create', table => 'Products');
    $api_r->get('products/:id')->name('apiv1_product')->to('table#list', table => 'Products');
    $api_ra->put('products/:id')->to('table#update', table => 'Products');
    $api_ra->post('products/:id')->to('table#update', table => 'Products');         #in case PUT is not supported
    $api_ra->delete('products/:id')->to('table#destroy', table => 'Products');

    # api/v1/job_templates
    $api_r->get('job_templates')->name('apiv1_job_templates')->to('job_template#list');
    $api_ra->post('job_templates')->to('job_template#create');
    $api_r->get('job_templates/:job_template_id')->name('apiv1_job_template')->to('job_template#list');
    $api_ra->delete('job_templates/:job_template_id')->to('job_template#destroy');

    # json-rpc methods not migrated to this api: echo, list_commands
    ###
    ## JSON API ends here
    #

    $self->gru->add_task(optipng        => \&OpenQA::Schema::Result::Jobs::optipng);
    $self->gru->add_task(reduce_result  => \&OpenQA::Schema::Result::Jobs::reduce_result);
    $self->gru->add_task(limit_assets   => \&OpenQA::Schema::Result::Assets::limit_assets);
    $self->gru->add_task(download_asset => \&OpenQA::Schema::Result::Assets::download_asset);
    $self->gru->add_task(scan_old_jobs  => \&OpenQA::Schema::Result::Needles::scan_old_jobs);
    $self->gru->add_task(scan_needles   => \&OpenQA::Schema::Result::Needles::scan_needles);

    $self->validator->add_check(
        datetime => sub {
            my ($validation, $name, $value) = @_;
            eval { DateTime::Format::SQLite->parse_datetime($value); };
            if ($@) {
                return 1;
            }
            return;
        });

    # start workers checker
    $self->_workers_checker;
    $self->_init_rand;

    # run fake dbus services in case of test mode
    if ($self->mode eq 'test') {
        log_warning('Running in test mode - dbus services mocked');
        require OpenQA::WebSockets;
        require OpenQA::Scheduler;
        OpenQA::IPC->ipc('', 1);
        OpenQA::WebSockets->new;
        OpenQA::Scheduler->new;
    }
}

sub run {
    # Start command line interface for application
    Mojolicious::Commands->start_app('OpenQA::WebAPI');
}

1;
# vim: set sw=4 et:
