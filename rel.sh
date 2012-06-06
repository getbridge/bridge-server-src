#!/bin/bash
rm -f "rel/bc-latest"
rm -rf rel/bc
set -e
./rebar generate
sed 's/__VERSION__/${VER}/g' $PWD/bridge-wrapper > rel/bc/bin/bridge
chmod u+x rel/bc/bin/bridge
cd rel/bc/lib/
echo -n "Unpacking .ez files"
for f in *.ez
do
echo -n "."
unzip $f > /dev/null
rm $f
done
echo
cd ../releases/
# Get the version of the only release in the system, our new app:
VER=`find . -maxdepth 1 -type d | grep -vE '^\.$' | head -n1 | sed 's/^\.\///g'`
echo "Ver: ${VER}, renaming .rel + .boot files correctly"
cd "${VER}"
mv bc.boot start.boot
cp bc.rel "bc-${VER}.rel"
cd ../../bin
mv bc start
cd ../../
rm -rf "bc_rel-${VER}"
mv bc "bc_rel-${VER}"
echo $VER > CURRENT_VERSION
ln -sf "bc_rel-${VER}" "bc-latest"
echo "OK"
