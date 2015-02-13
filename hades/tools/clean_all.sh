/home/bae/baeng/hades/tools/check  |grep "^=== " |awk '{print $2}' |xargs -i /home/bae/baeng/hades/tools/clean.sh {}

