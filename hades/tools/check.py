import os
import sys
import json
import cPickle

STATUS_FILE = os.environ["RUN_DIR"] + "/status/instance.status"

import logging
import subprocess

def run_cmd(cmd, out=False):
    stdout = ""
    try:
        stdout = subprocess.check_output(cmd, shell=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError, e:
        logging.warning("(%s) failed (%d)" % (cmd, e.returncode))
        logging.info(stdout)
        return e.returncode, None
    except Exception, e:
        logging.warning("(%s) failed (%s)" % (cmd, e))
        return -1, None
    else:
        if out: return 0, stdout
        return 0, None


def load_from_disk():
    try:
        with open(STATUS_FILE, "rb") as fd:
            a = cPickle.load(fd)
            return True, a
    except Exception, e:
        return False, None

error = False

ret, status_info = load_from_disk()
if not ret:
    status_info = {}

instance_list = [ k for k,v in status_info.items()]
container_list = [ v['container_id'] for k,v in status_info.items()]
ip_list = [ v['container_ip'] for k,v in status_info.items()]
uid_list = [ v['uid'] for k,v in status_info.items()]

### container process
print ">>>check container process"
cmd = """ps x |grep "lxc-start -n" | grep -v "grep" |awk '{print $1 " " $7}'"""
ret, output = run_cmd(cmd, True)
result = output.strip().split('\n')
for x in result:
    if len(x) < 3:
        continue
    pid, xid = x.split()
    if xid[:12] not in container_list:
        error = True
        print "=== %s (invalid container)" % xid

## container directory
print ">>>check container directory"
cmd = "cd %s/containers && ls -1" % os.environ['DOCKER_DIR']
ret, output = run_cmd(cmd, True)
container_dirs = output.strip().split('\n')
for xid in container_dirs:
    if len(xid) < 3:
        continue
    if xid[:12] not in container_list:
        error = True
        print "=== %s (invalid dir)" % xid

### network device
print ">>>check network device"
cmd = """ip link show |grep "master docker0" |grep -v "grep" |awk '{print $2}' |cut -c 1-12"""
ret, output = run_cmd(cmd, True)
network_devs = output.strip().split('\n')
for dev in network_devs:
    if len(dev) < 3:
        continue
    if dev not in container_list:
        error = True
        print "=== %s (invalid network device)" % dev

### cgroups
print ">>>check cgroup"
cmd = """find /sys/fs/cgroup/  -mindepth 3 -type d |xargs -i basename {} |sort -n |uniq"""
ret, output = run_cmd(cmd, True)
cgroup_dirs = output.strip().split('\n')
for xid in cgroup_dirs:
    if len(xid) != 64:
        continue
    if xid[:12] not in container_list:
        error = True
        print "=== %s (invalid cgroup dir)" % xid

### quota
print ">>>check quota uid"
cmd = "repquota -uv %s |grep \"^#\" |awk '{print $1}' |cut -c 2-" % os.environ['CONTAINER_DISK']
ret, output = run_cmd(cmd, True)
quota_uids = output.strip().split('\n')
for uid in quota_uids:
    if len(uid) < 2:
        continue
    uid = int(uid)
    if uid >= 20000 and uid < 30000:
        if uid not in uid_list:
            error = True
            print "*** invalid uid: ", uid

### iptables
print ">>>check iptable rules"
cmd = """iptables-save  |grep "\-A DOCKER" |awk '{print $12}'"""
ret, output = run_cmd(cmd, True)
iptable_rules = output.strip().split('\n')
for rule in iptable_rules:
    if len(rule) < 2:
        continue
    ip, port = rule.split(':')
    if ip not in ip_list:
        error = True
        print "*** invalid ip: ", ip

### /home/bae/share/instances
print ">>>check share instance directory"
cmd = """ls /home/bae/share/instances/ -1"""
ret, output = run_cmd(cmd, True)
instance_dirs = output.strip().split('\n')
for instance in instance_dirs:
    path = "/home/bae/share/instances/%s" % instance
    if os.path.isdir(path) and instance not in instance_list:
        error = True
        print "### %s (invalid instance dir)" % instance 

### /home/bae/share/logs
print ">>>check share log directory"
cmd = """ls /home/bae/share/logs/ -1"""
ret, output = run_cmd(cmd, True)
instance_dirs = output.strip().split('\n')
for instance in instance_dirs:
    path = "/home/bae/share/logs/%s" % instance
    if os.path.isdir(path) and instance not in instance_list:
        error = True
        print "### %s (invalid log dir)" % instance 

if error: 
    sys.exit(1)
sys.exit(0)


