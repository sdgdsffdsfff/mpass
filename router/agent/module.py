import os
import logging
import subprocess
import threading
import datetime
import time
import json
import urllib2 
import cPickle

import util
import global_context
from jinja2 import Template

NGINX_DIR = "/letv/nginx"

class Agent(object):
    def __init__(self):
        template = """
upstream {{ domain }} {
{% for addr in addrs %}
    server {{ addr }};
{% endfor %}
}

server {
    server_name {{ domain }};
    location / {
        proxy_pass http://{{ domain }}/;
        proxy_set_header X-Real-IP $remote_addr;
		client_max_body_size 40m;
    }
}
"""
        self.default_tpl = Template(template)

        template = """
upstream {{ domain }} {
{% for addr in addrs %}
    server {{ addr }};
{% endfor %}
}

"""
        self.upstream_tpl = Template(template)
        template = """
location /{{ path }} {
    proxy_pass http://{{ domain }};
    proxy_set_header X-Real-IP $remote_addr;
    client_max_body_size 40m;
}

"""
        self.location_tpl = Template(template)
        pass

    def init(self):
        import handler_manager
        _handlers = {
            "router_update"      : self.do_router_update,
            "router_remove"      : self.do_router_remove,
        }
        handler_manager.register_handlers(_handlers)
        return True

    def fini(self):
        return True

    def do_router_update(self, tid, msg):
        context = msg['context']
        domain = context["domain"]
        path = context.get("path", "")
        dict = {
            "domain" : domain,
            "addrs" : context["addrs"],
            "path" : path
        }
        result = 0
        
        try:
            if path != "":
                strconf = self.upstream_tpl.render(dict)
                filename = "%s/conf.d/%s/upstream-%s.conf" % (NGINX_DIR, domain, path)
                with open(filename, "w") as fd:
                    fd.write(strconf)

                strconf = self.location_tpl.render(dict)
                filename = "%s/conf.d/%s/location-%s.conf" % (NGINX_DIR, domain, path)
                with open(filename, "w") as fd:
                    fd.write(strconf)

            else:
                strconf = self.default_tpl.render(dict)
                filename = "%s/conf.d/%s.conf" % (NGINX_DIR, domain)
                with open(filename, "w") as fd:
                    fd.write(strconf)

            cmd = "%s/nginx reload" % (NGINX_DIR)
            ret, _ = util.run_cmd(cmd, out=False)
            if ret != 0:
                logging.warning("router_update failed: %d", ret)
                result = 1
        except Exception as e:
            logging.warning("router_update exception: %s", e)
            result = -1

        reply_msg = {
            'cmd' : 'common_reply',
            'context' : {
                'taskid' : context['taskid'],
                'result' : result,
            }
        }
        return 0, reply_msg 

    def do_router_remove(self, tid, msg):
        context = msg['context']
        domain = context["domain"]
        path = context.get("path", "")
        result = 0
        try:
            if path != "":
                file1 = "%s/conf.d/%s/upstream-%s.conf" % (NGINX_DIR, domain, path)
                file2 = "%s/conf.d/%s/location-%s.conf" % (NGINX_DIR, domain, path)
                cmd = "rm -f %s && rm -f %s && %s/nginx reload" % (file1, file2, NGINX_DIR)
            else:
                filename = "%s/conf.d/%s.conf" % (NGINX_DIR, domain)
                cmd = "rm -f %s && %s/nginx reload" % (filename, NGINX_DIR)
            ret, _ = util.run_cmd(cmd, out=False)
            if ret != 0:
                logging.warning("router_remove failed: %d", ret)
                result = 1
        except Exception as e:
            logging.warning("router_remove exception: %s", e)
            result = -1
        reply_msg = {
            'cmd' : 'common_reply',
            'context' : {
                'taskid' : context['taskid'],
                'result' : result,
            }
        }
        return 0, reply_msg 

g_agent = Agent()

def init():
    return g_agent.init()

def fini():
    g_agent.fini()

