#!/usr/bin/env perl

# Copyright (C) 2015 SUSE LLC
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use OpenQA::Schema;
use DBIx::Class::DeploymentHandler;
use DBIx::Class::Timestamps qw/now/;

sub {
    my $schema = shift;

    my $maxid = $schema->resultset("Jobs")->get_column('id')->max();

    while ($maxid > 0) {

        $schema->resultset('GruTasks')->create(
            {
                taskname => 'scan_old_jobs',
                priority => 1,
                args     => [$maxid, $maxid - 1000],
                run_at   => now(),
            });
        $maxid -= 1000;
    }
  }

