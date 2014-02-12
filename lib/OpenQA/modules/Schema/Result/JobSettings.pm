package Schema::Result::JobSettings;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('job_settings');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
    },
    key => {
        data_type => 'text',
    },
    value => {
        data_type => 'text',
    },
    job_id => {
        data_type => 'integer',
    },
    t_created => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    t_updated => {
        data_type => 'timestamp',
        default_value => 'datetime("now")',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(job => 'Schema::Result::Jobs', 'job_id');

1;