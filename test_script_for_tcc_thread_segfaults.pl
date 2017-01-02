use strict;
use warnings;

use Time::HiRes qw(sleep);
use C::Blocks;
use threads;


my $thread_sub = sub {
  for (1..10) {
    eval qq[
      clex {
        void foo$_() {}
      }
      1
    ];
  }
};

$thread_sub->();

my @t;
push @t, threads->create($thread_sub) for 1..5;

while (@t) {
  sleep 0.1;
  for (my $i = 0; $i < @t; ++$i) {
    $t[$i]->join, splice(@t, $i, 1), $i-- if $t[$i]->is_joinable;
  }
}


