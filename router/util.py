import logging
import subprocess

import global_context

"""
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
"""

def run_cmd(cmd, out=False):
    stdout = ""
    try:
        p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = p.communicate()
    except Exception, e:
        logging.warning("(%s) failed (%s)" % (cmd, e))
        return -1, None
    else:
        if out: return p.returncode, stdout
        return p.returncode, None

def log_debug(msg):
    if global_context.g_debug_mode: logging.debug(msg)

