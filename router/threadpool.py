# -*- coding: UTF-8 -*-

__all__ = [
    'makeRequests',
    'NoResultsPending',
    'NoWorkersAvailable',
    'ThreadPool',
    'WorkRequest',
    'WorkerThread'
]

# standard library modules
import sys
import threading
import Queue
import time

import logging

# exceptions
class NoResultsPending(Exception):
    """All work requests have been processed."""
    pass

class NoWorkersAvailable(Exception):
    """No worker threads available to process remaining requests."""
    pass

# internal module helper functions
def _handle_thread_exception(request, exc_info):
    #traceback.print_exception(*exc_info)
    pass


# utility functions
def makeRequests(callable_, args_list, callback=None,
        exc_callback=_handle_thread_exception):
    requests = []
    for item in args_list:
        if isinstance(item, tuple):
            requests.append(
                WorkRequest(callable_, item[0], item[1], callback=callback,
                    exc_callback=exc_callback)
            )
        else:
            requests.append(
                WorkRequest(callable_, [item], None, callback=callback,
                    exc_callback=exc_callback)
            )
    return requests

# classes
class WorkerThread(threading.Thread):
    def __init__(self, id, requests_queue, results_queue, poll_timeout=5, **kwds):
        threading.Thread.__init__(self, **kwds)
        self.setDaemon(1)
        self._waiting_queue = Queue.Queue(10)
        self._requests_queue = requests_queue
        self._results_queue = results_queue
        self._poll_timeout = poll_timeout
        self._dismissed = threading.Event()
        self.id = id
        self.busy = False
        self.task_begin = 0
        self.start()

    def run(self):
        logging.info("Thread (%d) running" % self.id)
        while True:
            if self._dismissed.isSet():
                # we are dismissed, break out of loop
                break
            # get next work request. If we don't get a new request from the
            # queue after self._poll_timout seconds, we jump to the start of
            # the while loop again, to give the thread a chance to exit.

            try:
                request = self._waiting_queue.get(False)
            except Queue.Empty:
                request = None    
            
            if not request:
                try:
                    request = self._requests_queue.get(True, self._poll_timeout)
                except Queue.Empty:
                    continue

                if self._dismissed.isSet():
                    # we are dismissed, put back request in queue and exit loop
                    self._requests_queue.put(request)
                    break
            try:
                self.busy = True
                self.task_begin = time.time()
                result = request.callable(self.id, *request.args)
                #request.callable(self.id, *request.args, **request.kwds)
                self.busy = False
                self._results_queue.put((request, result))
            except Exception, e:
                logging.warning("WARNING: Thread %d: exception: (%s)" % (self.id, str(e)) )
                import traceback
                logging.warning(traceback.format_exc())
                #request.exception = True
                self.busy = False
                self._results_queue.put((request, -1))
        logging.info("Thread (%d) exited" % self.id)
        
    def dismiss(self):
        self._dismissed.set()

class WorkRequest:
    def __init__(self, callable_, args=None, kwds=None, requestID=None,
            callback=None, exc_callback=_handle_thread_exception):
        if requestID is None:
            self.requestID = id(self)
        else:
            try:
                self.requestID = hash(requestID)
            except TypeError:
                raise TypeError("requestID must be hashable.")
        self.exception = False
        self.callback = callback
        self.exc_callback = exc_callback
        self.callable = callable_
        self.args = args or []
        self.kwds = kwds or {}

    def __str__(self):
        return "<WorkRequest id=%s args=%r kwargs=%r exception=%s>" % \
            (self.requestID, self.args, self.kwds, self.exception)

class ThreadPool(object):
    def __init__(self, num_workers, q_size=0, resq_size=0, poll_timeout=5):
        self._requests_queue = Queue.Queue(q_size)
        self._results_queue = Queue.Queue(resq_size)
        self.workers = []
        self.dismissedWorkers = []
        self.workRequests = {}
        self.createWorkers(num_workers, poll_timeout)

    def busyWorkers(self):
        return sum(1 for w in self.workers if w.busy)

    def getWorkersStatus(self):
        return [(w.busy, w.task_begin) for w in self.workers]

    def createWorkers(self, num_workers, poll_timeout=5):
        for i in range(num_workers):
            self.workers.append(WorkerThread(i, self._requests_queue,
                self._results_queue, poll_timeout=poll_timeout))

    def dismissWorkers(self, num_workers, do_join=False):
        """Tell num_workers worker threads to quit after their current task."""
        dismiss_list = []
        for i in range(min(num_workers, len(self.workers))):
            worker = self.workers.pop()
            worker.dismiss()
            dismiss_list.append(worker)

        if do_join:
            for worker in dismiss_list:
                worker.join()
        else:
            self.dismissedWorkers.extend(dismiss_list)

    def joinAllDismissedWorkers(self):
        """Perform Thread.join() on all worker threads that have been dismissed.
        """
        for worker in self.dismissedWorkers:
            worker.join()
        self.dismissedWorkers = []

    def putRequest(self, request, block=True, timeout=0):
        """Put work request into work queue and save its id for later."""
        assert isinstance(request, WorkRequest)
        # don't reuse old work requests
        assert not getattr(request, 'exception', None)
        self._requests_queue.put(request, block, timeout)
        self.workRequests[request.requestID] = request

    def poll(self, block=False):
        """Process any new results in the queue."""
        while True:
            # still results pending?
            if not self.workRequests:
                raise NoResultsPending
            # are there still workers to process remaining requests?
            elif block and not self.workers:
                raise NoWorkersAvailable
            try:
                # get back next results
                request, result = self._results_queue.get(block=block)
                # has an exception occured?
                if request.exception and request.exc_callback:
                    request.exc_callback(request, result)
                # hand results to callback, if any
                if request.callback and not \
                       (request.exception and request.exc_callback):
                    request.callback(request, result)
                del self.workRequests[request.requestID]
            except Queue.Empty:
                break

    def wait(self):
        """Wait for results, blocking until all have arrived."""
        while 1:
            try:
                self.poll(True)
            except NoResultsPending:
                break
        print "All thread exited"
        logging.debug("All thread exited")

