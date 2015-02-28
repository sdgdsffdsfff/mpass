import logging

g_handlers = {

}

def register_handlers(handlers):
    global g_handlers
    for k, v in handlers.items():
        if k in g_handlers:
            logging.warning("handler %s registered already" % k)
            continue
        g_handlers[k] = v    

def get(k):
    return g_handlers.get(k, None)

