#!/bin/sh
# Started by on(1) so it outlives the ssh session that launched it.
# Args: binary, config, log, pid-file, exit-file.
bin=$1
conf=$2
log=$3
pidf=$4
exitf=$5
bindir=${bin%/*}
rootdir=${bindir%/*}
export LD_LIBRARY_PATH="$rootdir/lib"
trap '' HUP
"$bin" -c "$conf" >"$log" 2>&1 </dev/null &
echo $! >"$pidf"
wait $!
echo $? >"$exitf"
