import sys
import os
import tempfile

import yaml
import logging
import logging.handlers

conf_file  = sys.argv[1]
app_update = False if sys.argv[2] == "0" else True
runtime_type = sys.argv[3] if len(sys.argv) > 3 else ""
appconf = None

APPCONF_LOG = "/home/bae/log/appconf.log"
LOG = logging.getLogger(__name__)
handler = logging.handlers.RotatingFileHandler(APPCONF_LOG, maxBytes=20*1024*1024, backupCount=10)
handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s:  %(message)s"))
LOG.setLevel(logging.DEBUG)
LOG.addHandler(handler)
os.chmod(APPCONF_LOG, 0666)

def handle_environment(appconf):
    if 'environment' in appconf:
        if not isinstance(appconf['environment'], dict):
            LOG.info("'environment' must be a 'dict'\n")
            return 1
    
        l = ["export %s=%s"%(k,v) for k,v in appconf['environment'].items()]
        output = '\n'.join(l)
    else:
        output = ""
    envfile = "/home/bae/.user_profile"
    with open(envfile, "w") as fd:
        fd.write("%s\n" % output)
    return 0

def handle_crond(appconf):
    if 'crond' in appconf:
        if not isinstance(appconf['crond'], dict):
            LOG.info("'crond' must be a 'dict'\n")
            return 1

        if 'service' in appconf['crond']:
            if not isinstance(appconf['crond']['service'], bool):
                LOG.info("'crond.service' must be a 'boolean'\n")
                return 1
            enable = appconf['crond']['service']
        else:
            enable = False

        if 'crontab' in appconf['crond']:
            if not isinstance(appconf['crond']['crontab'], list):
                LOG.info("'crond.crontab' must be a 'list'\n")
                return 1
            output = '\n'.join(appconf['crond']['crontab'][0:10])
        else:
            output = ""
    else:
        enable = False
        output = ""

    if not enable:
        if app_update:
            cmd = "killall -9 cron"
            os.system(cmd)
        return 0

    fd, tmpfile = tempfile.mkstemp()
    os.write(fd, "%s\n" % output)
    os.close(fd)
    os.system("crontab -u bae %s" % tmpfile)

    if app_update:
        cmd = """
pid=$(cat /var/run/crond.pid);
[ $? -ne 0 ] && {
    /usr/sbin/cron
} || {
    ps -p $pid >/dev/null 2>&1;
    [ $? -ne 0 ] && {
        /usr/sbin/cron
    }
}
"""
    else:
        cmd = "/usr/sbin/cron"
    os.system(cmd)
    return 0

def handle_sshd(appconf):
    if 'sshd' in appconf:
        if not isinstance(appconf['sshd'], dict):
            LOG.info("'sshd' must be a 'dict'\n")
            return 1

        if 'service' in appconf['sshd']:
            if not isinstance(appconf['sshd']['service'], bool):
                LOG.info("'sshd.service' must be a 'boolean'\n")
                return 1
            enable = appconf['sshd']['service']
        else:
            enable = False

        if 'public_keys' in appconf['sshd']:
            if not isinstance(appconf['sshd']['public_keys'], list):
                LOG.info("'sshd.public_keys' must be a 'list'\n")
                return 1
            output = '\n'.join(appconf['sshd']['public_keys'])
        else:
            output = ""
        if 'port' in appconf['sshd']:
            if not isinstance(appconf['sshd']['port'], int):
                LOG.info("'sshd.port' must be a 'int'\n")
                return 1
            port = appconf['sshd']['port']
            if port < 1 or port > 65535:
                LOG.info("'sshd.port' must withn [1, 65535]\n")
                return 1
        else:
            port = 22
    else:
        enable = False
        output = ""

    if not enable:
        if app_update:
            cmd = "killall -9 sshd"
            os.system(cmd)
        return 0

    ak_file = "/home/bae/.ssh/authorized_keys"
    with open(ak_file, "w") as fd:
        fd.write("%s\n" % output)

    cmd = "chown bae:bae %s; chmod 600 %s" % (ak_file, ak_file)
    os.system(cmd)

    if app_update:
        cmd = """
pid=$(cat /var/run/sshd.pid);
[ $? -ne 0 ] && {
    /usr/sbin/sshd -p %d
} || {
    ps -p $pid >/dev/null 2>&1;
    [ $? -ne 0 ] && {
        /usr/sbin/sshd -p %d
    }
}
""" % (port, port)
    else:
        cmd = "/usr/sbin/sshd -p %d" % port
    os.system(cmd)
    return 0

def handle_system_packages(appconf):
    if 'system_packages' in appconf:
        if not isinstance(appconf['system_packages'], list):
            LOG.info("'system_packages' must be a 'list'\n")
            return 1

        for pkg in appconf['system_packages']:
            cmd = "apt-get install -y --force-yes %s" % pkg
            ret = os.system(cmd)
            if ret != 0:
                LOG.info("install '%s' failed\n" % pkg)
                return 1
    return 0

try:
    with open(conf_file) as fd:
        try:
            data = fd.read()
            appconf = yaml.safe_load(data)
        except Exception, e:
            LOG.info("invalid 'app.conf'\n")
            LOG.info(str(e))
            sys.exit(2)

    if not appconf:
        sys.exit(0)

    if not isinstance(appconf, dict):
        LOG.info("'app.conf' must be a 'dict'\n")
        sys.exit(3)

    ret = handle_environment(appconf)
    if ret != 0: sys.exit(4)
    ret = handle_crond(appconf) 
    if ret != 0: sys.exit(5)
    ret = handle_sshd(appconf)
    if ret != 0: sys.exit(6)
    if runtime_type == "custom":
        ret = handle_system_packages(appconf)
        if ret != 0: sys.exit(7)

except Exception, e:
    LOG.warn("unknown exception\n")
    import traceback
    LOG.warn(traceback.format_exc())
    sys.exit(1)
    
sys.exit(0)

