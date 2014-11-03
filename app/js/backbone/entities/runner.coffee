@App.module "Entities", (Entities, App, Backbone, Marionette, $, _) ->

  testIdRegExp = /\[(.{3})\]$/

  ## create our own private bus channel for communicating with
  ## 3rd party objects outside of our application
  runnerChannel = _.extend {}, Backbone.Events

  class Entities.Runner extends Entities.Model
    defaults: ->
      iframes: []
      browser: null
      version: null

  ## need to compose this runner with models for each panel
  ## DOM / XHR / LOG
  ## and partial each test (on test run) if its chosenId...?
    initialize: ->
      @hooks            = App.request "hook:entities"
      @commands         = App.request "command:entities"
      @satelliteEvents  = App.request "satellite:events"
      @hostEvents       = App.request "host:events"

    setContentWindow: (@contentWindow, @$remoteIframe) ->

    setIframe: (@iframe) ->

    setEclPatch: (@patchEcl) ->

    setEclHook: (@patchHook) ->

    setEclRestore: (@eclRestore) ->

    setOptions: (@options) ->

    runSauce: ->
      socket = App.request "socket:entity"

      ## when we get a response from the server with
      ## the jobName we notify all parties
      socket.emit "run:sauce", @iframe, (jobName) =>
        @trigger "sauce:running", jobName

    getTestCid: (test) ->
      ## grab the test id from the test's title
      matches = testIdRegExp.exec(test.title)

      ## use the captured group if there was a match
      matches and matches[1]

    getIdToAppend: (cid) ->
      " [" + cid + "]"

    logResults: (test) ->
      @trigger "test:results:ready", test

    revertDom: (command) ->
      @trigger "revert:dom", command.getSnapshot(),
        id:   command.id
        el:   command.getEl()
        attr: command.get("highlightAttr")

    highlightEl: (command, init = true) ->
      @trigger "highlight:el", command.getEl(),
        id: command.id
        init: init

    switchToBrowser: (browser, version) ->
      @trigger "switch:to:manual:browser", browser, version

    setBrowserAndVersion: (browser, version) ->
      @set
        browser: browser
        version: version

    setTestRunner: (runner) ->
      ## store the test runner as a property on ourselves
      @runner = runner

      ## override the runSuite function on our runner instance
      ## this is used to generate properly unique regex's for grepping
      ## through a specific test
      socket = App.request "socket:entity"

      @listenTo socket, "sauce:job:start", (obj) ->
        @trigger "sauce:job:start", obj

      ## whenever our socket fires 'test:changed' we want to
      ## proxy this to everyone else
      @listenTo socket, "test:changed", @triggerLoadIframe

      if App.config.env("satellite")
        _.each @hostEvents, (event) =>
          @listenTo socket, event, (args...) =>
            @trigger event, args...

      if App.config.env("host")
        _.each @satelliteEvents, (event) =>
          @listenTo socket, event, (args...) =>
            @trigger event, args...

        @listenTo socket, "command:add", (args...) =>
          @commands.add args...

      ## dont overload the runSuite fn if we're in CI mode
      return @ if App.config.env("ci")

      runner = @

      @runner.runSuite = _.wrap @runner.runSuite, (runSuite, rootSuite, fn) ->
        ## the runSuite function is recursively called for each individual suite
        ## since we iterate through all tests and all suites initially we need
        ## to bail early if this isnt the root suite
        return runSuite.call(@, rootSuite, fn) if not rootSuite.root

        runner.trigger "before:add"

        runner.iterateThroughRunnables rootSuite

        runner.trigger "after:add"

        ## grep for the correct test / suite by its id if chosenId is set
        ## or all the tests
        ## we need to grep at the last possible moment because if we've chosenId
        ## a runnable but then deleted it afterwards, then we'll incorrectly
        ## continue to grep for it.  instead we need to do a check to ensure
        ## we still have the runnable's cid which matches our chosenId id
        @grep runner.getGrep(rootSuite)

        runSuite.call(@, rootSuite, fn)

      return @

    ## iterates through both the runnables tests + suites if it has any
    iterateThroughRunnables: (runnable) ->
      _.each [runnable.tests, runnable.suites], (array) =>
        _.each array, (runnable) =>
          @generateId runnable

    ## generates an id for each runnable and then continues iterating
    ## on children tests + suites
    generateId: (runnable) ->
      ## iterating on both the test and its parent (the suite)
      ## bail if we're the root runnable
      ## or we've already processed this tests parent
      return if runnable.root or runnable.added

      runner = @

      ## parse the cid out of the title if it exists
      runnable.cid ?= runner.getTestCid(runnable)

      ## allow to get the original title
      runnable.originalTitle = ->
        @title.replace runner.getIdToAppend(runnable.cid), ""

      ## dont fire duplicate events if this is already fired
      ## its 'been added' event
      return if runnable.added

      runnable.added = true

      ## tests have a runnable of 'test' whereas suites do not have a runnable property
      event = runnable.type or "suite"

      ## we need to change our strategy of displaying runnables
      ## if grep is set (runner.options.grep)  that means the user
      ## has written a .only on a suite or a test, and in that case
      ## we dont want to display the tests or suites unless they match
      ## our grep.
      grep = runner.options?.grep

      ## grep will always be set to something here... even /.*/

      ## trigger the add events so our UI can begin displaying
      ## the tests + suites
      if grep and event is "suite"
        count = 0
        runnable.eachTest (test) ->
          count += 1 if grep.test(test.fullTitle())
        runner.trigger "suite:add", runnable if count > 0

      if grep and event is "test"
        runner.trigger "test:add", runnable if grep.test(runnable.fullTitle())

      ## recursively apply to all tests / suites of this runnable
      runner.iterateThroughRunnables(runnable)

      return runnable

    getCommands: ->
      @commands

    startListening: ->
      @setListenersForAll()
      @setListenersForCI() if App.config.env("ci")
      @setListenersForWeb() if not App.config.env("ci")

    setListenersForAll: ->
      ## partials in the runnable object
      ## our private channel
      ## the iframes contentWindow
      ## and the iframe string
      @runner.on "test", (test) =>
        @patchEcl
          runnable: test
          channel: runnerChannel
          contentWindow: @contentWindow
          $remoteIframe: @$remoteIframe

        @patchHook "test"

    setListenersForCI: ->

    setListenersForWeb: ->
      socket = App.request "socket:entity"

      @listenTo runnerChannel, "all", (type, id, attrs, hook) ->
        ## if we're in satellite mode then we need to
        ## broadcast this through websockets
        if App.config.env("satellite")
          attrs = @transformEmitAttrs(attrs)
          socket.emit "command:add", attrs, type, id, hook
        else
          @commands.add attrs, type, id, hook

      ## mocha has begun running the specs per iframe
      @runner.on "start", =>
        ## wipe out all listeners on our private runner bus
        @trigger "runner:start"

      @runner.on "end", =>
        @trigger "runner:end"

      @runner.on "suite", (suite) =>
        @trigger "suite:start", suite

      @runner.on "suite end", (suite) =>
        @trigger "suite:stop", suite

      # @runner.on "suite end", (suite) ->
      #   console.warn "suite end", suite

      @runner.on "fail", (test, err) =>
        console.warn("runner has failed", test, err)

        ## set the AssertionError on the test
        test.err = err

        ## if this is a hook then we need to make sure
        ## we still submit the test:end event and since
        ## this is a hook we know its related to the first
        ## test of our parent suite
        @hookFailed(test, err) if test.type is "hook"

      @runner.on "hook", (hook) =>
        ## if our hook doesnt have an associated test ctx
        ## then we need to patchEcl with the first test
        ## we can find
        if not hook.ctx.currentTest
          test = @getTestFromHook(hook, hook.parent)

          @patchEcl
            hook: @getHookName(hook)
            runnable: test
            channel: runnerChannel
            contentWindow: @contentWindow
            $remoteIframe: @$remoteIframe
            iframe: @iframe

        ## dynamically changes the current patched test's hook name
        @patchHook @getHookName(hook)

      ## when a hook ends we want to repatch
      ## Ecl with the associated test from the hook
      ## this is due to the order of events mocha
      ## fires when our tests run
      @runner.on "hook end", (hook) =>
        ## we only care to re-patch the hook name if
        ## we have a current test, else the next test
        ## will naturally patchEcl again for itself
        hook.removeAllListeners()
        @patchHook("test") if hook.ctx.currentTest

      ## if a test is pending mocha will only
      ## emit the pending event instead of the test
      ## so we normalize the pending / test events
      @runner.on "pending", (test) =>
        @trigger "test", test

      @runner.on "test", (test) =>
        @trigger "test:start", test

      @runner.on "test end", (test) =>
        @trigger "test:end", test
        test.removeAllListeners()
        @eclRestore()
      ## start listening to all the pertinent runner events

    trigger: (event, args...) ->
      ## because of defaults the change:iframes event
      ## fires before our initialize (which is stupid)
      return if not @satelliteEvents

      socket = App.request "socket:entity"

      ## if we're in satellite mode and our event is
      ## a satellite event then emit over websockets
      if App.config.env("satellite") and event in @satelliteEvents
        args   = @transformRunnableArgs(args)
        return socket.emit event, args...

      ## if we're in host mode and our event is a
      ## satellite event AND we have a remoteIrame defined
      if App.config.env("host") and event in @hostEvents and @$remoteIframe
        return socket.emit event, args...

      ## else just do the normal trigger and
      ## remove the satellite namespace
      super event, args...

    transformEmitAttrs: (attrs) ->
      obj = {}

      ## normally we'd use a reduce here but for some reason
      ## on dom attrs the reduce completely barfs and is not
      ## able to iterate over the object.
      for key, value of attrs
        obj[key] = value if @isWebSocketCompatibleValue(value)

      obj

    ## make sure this value is capable
    ## of being sent through websockets
    isWebSocketCompatibleValue: (value) ->
      switch
        when _.isElement(value)                           then false
        when _.isObject(value) and _.isElement(value[0])  then false
        when _.isFunction(value)                          then false
        else true

    transformRunnableArgs: (args) ->
      ## pull off these direct properties
      props = ["title", "cid", "root", "pending", "stopped", "state", "duration", "type"]

      ## pull off these parent props
      parentProps = ["root", "cid"]

      ## fns to invoke
      fns = ["originalTitle", "fullTitle", "slow", "timeout"]

      _(args).map (arg) =>
        ## transfer direct props
        obj = _(arg).pick props...

        ## transfer parent props
        if parent = arg.parent
          obj.parent = _(parent).pick parentProps...

        ## transfer the error as JSON
        if err = arg.err
          err.host = @$remoteIframe.prop("contentWindow").location.host
          obj.err = JSON.stringify(err, ["message", "type", "name", "stack", "fileName", "lineNumber", "columnNumber", "host"])

        ## invoke the functions and set those as properties
        _.each fns, (fn) ->
          obj[fn] = _.result(arg, fn)

        obj

    ## recursively tries to find the test associated
    ## with the hook
    getTestFromHook: (hook, suite) ->
      ## if theres already a currentTest use that
      return test if test = hook.ctx.currentTest

      ## there is a bug where if you have set an 'only'
      ## and you're running a visit within a hook
      ## then this will return the incorrect test
      ## it will return the very first test instead of
      ## our actual running test.  i've looked through
      ## mocha's source and cannot find any way to figure
      ## out which test is running in this scenario.
      ## so i think the only solution is to look at the grep
      ## and grep for the first test that matches it
      grep = @runner._grep
      if grep.toString() isnt "/.*/"
        return test if test = @getFirstTestByFn suite, (test) ->
          grep.test _.result(test, "fullTitle")

      ## else go look for the test because our suite
      ## is most likely the root suite (which does not share a ctx)
      if suite.tests.length
        return suite.tests[0]
      else
        @getTestFromHook(hook, suite.suites[0])

    getHookName: (hook) ->
      ## find the name of the hook by parsing its
      ## title and pulling out whats between the quotes
      name = hook.title.match(/\"(.+)\"/)
      name and name[1]

    hookFailed: (hook, err) ->
      ## finds the test by returning the first test from
      ## the parent or looping through the suites until
      ## it finds the first test
      test = @getTestFromHook(hook, hook.parent)
      test.err = err
      test.state = "failed"
      test.hook = @getHookName(hook)
      test.failedFromHook = true
      @trigger "test:end", test.parent.tests[0]

    stop: ->
      ## clear out the commands
      @commands.reset([], {silent: true})

      ## remove all the listeners from EventEmitter
      @runner.removeAllListeners()

      ## cleanup any of our handlers
      @stopListening()

      ## remove all references to other objects
      ## clear twice to nuke _previousAttributes
      @clear()
      @clear()

      ## null out these properties
      @runner         = null
      @contentWindow  = null
      @$remoteIframe  = null
      @iframe         = null
      @hooks          = null
      @commands       = null
      @chosen         = null

    start: (iframe) ->
      @setIframe iframe

      @triggerLoadIframe @iframe

    triggerLoadIframe: (iframe, opts = {}) ->
      ## first we want to make sure that our last stored
      ## iframe matches the one we're receiving
      return if iframe isnt @iframe

      _.defaults opts,
        chosenId: @get("chosenId")
        browser:  @get("browser")
        version:  @get("version")

      ## clear out the commands
      @commands.reset([], {silent: true})

      ## always reset @options.grep to /.*/ so we know
      ## if the user has removed a .only in between runs
      ## if they havent, it will just be picked back up
      ## by mocha
      @options.grep = /.*/

      ## set any outstanding test to pending and stopped
      ## so we bypass all old ones
      @runner.suite.eachTest (test) ->
        test.pending = true
        test.stopped = true
        while obj = test.parent
          return if obj.stopped
          obj.pending = true
          obj.stopped = true
          obj = obj.parent

      ## tells different areas of the app to prepare
      ## for the resetting of the test run
      @trigger "reset:test:run"

      ## tells the iframe view to load up a new iframe
      @trigger "load:iframe", @iframe, opts

    hasChosen: ->
      !!@get("chosenId")

    getChosen: ->
      @chosen

    updateChosen: (id) ->
      ## set chosenId as runnable if present else unset
      if id then @set("chosenId", id) else @unset("chosenId")

    setChosen: (runnable) ->
      if runnable
        @chosen = runnable
      else
        @chosen = null

      @updateChosen(runnable?.id)

      ## always reload the iframe
      @triggerLoadIframe @iframe

    ## this recursively loops through all tests / suites
    ## plucking out their cid's and returning those
    ## this should be refactored since it creates an N+1 loop
    ## through all runnables.  instead this should happen during
    ## the original loop through to ensure we have cid's
    getRunnableCids: (root, ids) ->
      ids ?= []

      ## make sure we push our own cid in here
      ## when we're a suite but not the root!
      ids.push root.cid if root.cid

      _.each root.tests, (test) ->
        ids.push test.cid

      _.each root.suites, (suite) =>
        @getRunnableCids suite, ids

      ids

    getFirstTestByFn: (root, fn) ->
      ## loop through each test applying
      ## the fn and return the first that matches
      for test in root.tests
        return test if fn(test)

      ## return recursively
      for suite in root.suites
        return @getFirstTestByFn(suite, fn)

    getGrep: (root) ->
      console.warn "GREP IS: ", @options.grep
      return re if re = @parseMochaGrep(@options.grep)

      chosenId = @get("chosenId")

      ## if we have a chosenId model and its in our runnables cid
      if chosenId and chosenId in @getRunnableCids(root)
        ## create a regex based on the id of the suite / test
        return new RegExp @escapeId("[" + chosenId + "]")

      ## lets remove our chosenId runnable since its no longer with us
      else
        @unset "chosenId"

      return /.*/ if not @hasChosen()

    parseMochaGrep: (re) ->
      re = re.toString()

      ## continue on if this is just a regex matching anything
      return if @isDefaultGrep(re)

      ## else if this isnt /.*/ we know the user has used a .only
      ## and we need to .....

      ## replace any single character except for digits,
      ## letters, [] or whitespaces
      re = re.replace /[^a-zA-Z0-9\[\]\s]/g, ""

      ## test the new re string against our testIdRegExp
      matches = testIdRegExp.exec(re)

      ## bail if this doesnt match what we expect
      return if not matches

      ## dont do anything if the matched id is our chosenId
      return if matches[1] is @get("chosenId")

      ## else if at this point if we have matches and its not
      ## our chosenId runnable, we need to unset what is currently
      ## chosenId and we need to choose this new runnable by its cid
      @unset "chosenId"

      return new RegExp @escapeId("[" + matches[1] + "]")

    isDefaultGrep: (str) ->
      str.toString() is "/.*/"

    escapeId: (id) ->
      id.replace(/[-\/\\^$*+?.()|[\]{}]/g, '\\$&');

    ## tell our runner to run our iframes mocha suite
    runIframeSuite: (iframe, contentWindow, remoteIframe, options, fn) ->
      ## options are optional and so if fn is undefined
      ## we automatically set it to options
      ## this allows consumers to pass a fn
      ## as the last argument even though it
      ## will be received as options
      if _.isUndefined(fn)
        fn = options

      ## store the current iframe
      @setIframe iframe

      ## store the content window so we can
      ## pass this along to our Eclectus methods
      @setContentWindow contentWindow, remoteIframe

      ## trigger the before run event
      @trigger "before:run"

      ## trigger this event if we're not using the default
      ## grep so we can remove existing tests
      @trigger "exclusive:test" if not @isDefaultGrep(@options.grep)

      ## we need to reset the runner.test to undefined
      ## when the user clicks the reload button, mocha
      ## will think that the currentTest is really the
      ## last test that was run.  so we always reset
      ## the state of the runner to prevent problems
      @runner.test = undefined

      ## don't attempt to run any tests if we're in manual
      ## testing mode and our iframe is not readable
      return if not remoteIframe.isReadable()

      ## reupdate chosen with the passed in chosenId
      ## this allows us to pass the chosenId around
      ## through websockets
      @updateChosen(options.chosenId)

      ## run the suite for the iframe
      ## right before we run the root runner's suite we iterate
      ## through each test and give it a unique id
      t = Date.now()

      @runner.runSuite contentWindow.mocha.suite, (err) =>
        ## its possible there is no runner when this
        ## finishes if the user navigated away from
        ## the tests
        return if not @runner

        ## trigger the after run event
        @trigger "after:run"

        @runner.emit "eclectus end"

        console.log "finished running the iframes suite!", Date.now() - t

        fn?(err)

  App.reqres.setHandler "runner:entity", (testRunner, options, patch, hook, restore) ->
    ## always set grep if its not already set
    options.grep ?= /.*/

    ## store the actual testRunner on ourselves
    runner = new Entities.Runner
    runner.setTestRunner testRunner
    runner.setOptions options
    runner.setEclPatch patch
    runner.setEclHook hook
    runner.setEclRestore restore
    runner.startListening()
    runner
