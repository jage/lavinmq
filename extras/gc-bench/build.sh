build () 
{ 
    name=$1;
    dir=$2;
    ( cd $dir && sed 's|require "./typetable"|require "./zz_typetable"|' $S/bench/gc_pauses.cr > src/zz_gc_pauses.cr;
    cp $S/bench/typetable.cr src/zz_typetable.cr;
    printf 'require "./zz_gc_pauses"\nrequire "./lavinmq"\n' > src/zz_bench.cr;
    crystal build --release src/zz_bench.cr -o $S/brokers/lavinmq-$name > $S/brokers/build-$name.log 2>&1 && echo "$name built" || tail -n 10 $S/brokers/build-$name.log;
    rm -f src/zz_*.cr )
}
