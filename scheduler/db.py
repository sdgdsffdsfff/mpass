import json
import copy

class Database(object):
    def __init__(self):
        self._load()

    def _load(self):
        try:
            with open("db.json") as fd:
                 self.db = json.load(fd)
        except:
            self.db = {
                 "apps" : {},
                 "instances" : {}
            }

    def _sync(self):
        with open("db.json", "w") as fd:
            json.dump(self.db, fd)

    def appCreate(self, name, context):
        apps = self.db["apps"]
        if name in apps:
            return None, "exits"
        apps[name] = {
            "domain" : context["domain"],
            "path"   : context["path"],
            "type"   : context["type"],
            "port"   : context["port"],
            "status" : 0
        }
        instances = self.db["instances"]
        instances[name] = {}
        self._sync()
        return apps[name], None

    def appDestroy(self, name):
        apps = self.db["apps"]
        if name not in apps:
            return "no such app"
        instances = self.db["instances"]
        if len(instances[name]) != 0:
            return "has instances"
        apps.pop(name)
        instances.pop(name)
        self._sync()
        return None
        
    def appGet(self, name):
        apps = self.db["apps"]
        return copy.deepcopy(apps.get(name, None))

    def instanceCreate(self, name, context):
        instances = self.db["instances"]
        instances[name][context["instance"]] = { 
            "status" : "running",
            "node" : context["node"],
            "vip" :  context["vip"],
            "port" : context["port"],
            "group" : context["group"]
        }
        self._sync()
        return True

    def instanceDestroy(self, name, instance):
        instances = self.db["instances"]
        instances[name].pop(instance)
        self._sync()

    def instanceGet(self, name):
        instances = self.db["instances"]
        return copy.deepcopy(instances.get(name, {}))

