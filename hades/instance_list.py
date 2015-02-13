import sys
import json
import cPickle

STATUS_FILE = "/home/bae/run/baeng/hades/status/instance.status"

def load_from_disk():
        try:
            with open(STATUS_FILE, "rb") as fd:
                a = cPickle.load(fd)
                l = [k for k in a.keys() if k.find('@') == -1]
                for k in l:
                    del a[k]
                print json.dumps(a)
                return True
        except Exception, e:
            return False

ret = load_from_disk()
if ret:
    sys.exit(0)
else:
    sys.exit(1)



