#!/bin/bash   
set -e
rm -rf rel/bc 
./rebar generate -f
cd rel/bc/lib/
echo -n "Unpacking .ez files"
for f in *.ez
do
echo -n "."
unzip $f > /dev/null
rm $f
done
echo
echo "OK"
