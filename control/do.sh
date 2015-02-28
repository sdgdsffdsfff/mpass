function get_code()
{
	local app=$1
	local svnurl=$2
	workdir="/letv/run/mpass/control/$app"
	mkdir -p $workdir
	cd $workdir
	rm -rf *
	svn co --username chenyifei --password @ThtssqcBjwls5q -q $svnurl app || {
		echo "svn co failed";
		exit 1;
	}
	find app -name ".svn" |xargs rm -rf
}

FUNC=$1
shift

$FUNC "$@"
exit 0

