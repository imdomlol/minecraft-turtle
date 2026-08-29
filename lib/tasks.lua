--[[----------------------------------------------------------------------
  lib/tasks.lua -- a tiny cooperative task scheduler: run several
  independent coroutines side by side, each able to add MORE tasks to the
  same running scheduler as it goes (unlike parallel.waitForAll, which
  only ever runs the fixed set it started with).

  Extracted out of lib/fleet.lua's own runTasks() (originally written so
  a turtle could answer a new incoming exec command without waiting for a
  still-running one to finish -- see that file's history) once
  lib/remote.lua needed the exact same thing for the controller's own
  relay-command polling: both are "keep listening for new work forever,
  and run each new task alongside whatever's already in flight," not a
  one-shot fixed batch.

  M.new() returns a scheduler with two methods:
    sched.addTask(fn, onError) -- starts `fn` as a new coroutine
      immediately (may resume more than once, yielding to os.pullEvent()
      like any other CraftOS coroutine). `onError`, if given, is called
      with the error message instead of propagating it if `fn` errors;
      omit to let a task's error take down the whole scheduler (matches
      parallel.waitForAll's own default behavior).
    sched.run() -- blocks forever (or until every task has finished AND
      no more are added -- see below), dispatching each os.pullEvent()
      to whichever tasks are currently waiting on that event type.

  A task started via addTask() from OUTSIDE any other task (i.e. before
  sched.run() -- see M.new()'s own initial task, or a caller building its
  initial set) works the same as one added by a task that's already
  running (e.g. lib/remote.lua's pollLoop calling addTask() for each
  newly-polled command) -- there's no distinction between "initial" and
  "later" tasks once the scheduler is running.
------------------------------------------------------------------------]]

local unpack = table.unpack or unpack

local M = {}

function M.new()
  local tasks = {}
  local sched = {}

  local function removeDead()
    local kept = {}
    for _, task in ipairs(tasks) do
      if coroutine.status(task.co) ~= "dead" then kept[#kept + 1] = task end
    end
    tasks = kept
  end

  function sched.addTask(fn, onError)
    local task = { co = coroutine.create(fn), filter = nil, onError = onError }
    tasks[#tasks + 1] = task
    local ok, filter = coroutine.resume(task.co)
    if not ok then
      if task.onError then task.onError(filter) else error(filter, 0) end
    else
      task.filter = filter
    end
    removeDead()
  end

  -- Blocks until `tasks` is empty (every task finished, or errored with
  -- an onError that didn't add a replacement) -- a scheduler meant to run
  -- forever should always have at least one long-lived task (a "keep
  -- polling" loop) that never itself finishes.
  function sched.run()
    while #tasks > 0 do
      local event = { os.pullEvent() }
      local taskCount = #tasks
      for i = 1, taskCount do
        local task = tasks[i]
        if task and (task.filter == nil or task.filter == event[1]) then
          local ok, filter = coroutine.resume(task.co, unpack(event))
          if not ok then
            if task.onError then task.onError(filter) else error(filter, 0) end
          else
            task.filter = filter
          end
        end
      end
      removeDead()
    end
  end

  return sched
end

return M
