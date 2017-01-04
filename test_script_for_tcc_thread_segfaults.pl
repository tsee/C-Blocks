use strict;
use warnings;

use Time::HiRes qw(sleep);
use C::Blocks;
use threads;


my $thread_sub = sub {
  for (1..100) {
    eval qq[
      clex {
        void foo$_() {}
      }
      1
    ];
  }
};


my $nthreads = 3;
my @t;
push @t, threads->create($thread_sub) for 1..$nthreads;

warn("Spawned $nthreads threads");

while (@t) {
  sleep 0.1;
  for (my $i = 0; $i < @t; ++$i) {
    if ($t[$i]->is_joinable) {
      warn("Thread " . ($i + 1) . " of " . @t . " remaining is joinable");
      $t[$i]->join;
      warn("Joined thread");
      splice(@t, $i, 1);
      $i--;
    }
  }
}


warn("Got to end of script");


