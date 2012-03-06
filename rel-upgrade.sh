#!/bin/bash   
set -e
rm rel/bc -fr
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
