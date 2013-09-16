{Base}  = require 'bongo'
recurly = require 'koding-payment'

module.exports = class JRecurly extends Base

  {secure, dash} = require 'bongo'
  {difference, extend} = require 'underscore'

  JUser = require '../user'

  @share()

  @set
    sharedMethods  :
      static       : [
        'getBalance', 'setAccount', 'getAccount', 'getTransactions'
      ]

  @setAccount = secure (client, data, callback)->
    {delegate}     = client.connection
    JSession       = require '../session'
    JSession.one {clientId: client.sessionToken}, (err, session) =>
      {username, firstName, lastName} = delegate.profile
      extend data, {username, firstName, lastName}
      data.ipAddress = session?.clientIPAddress or '0.0.0.0'

      JUser.fetchUser client, (err, user)->
        data.email = user.email
        recurly.setAccount "user_#{delegate._id}", data, (err, res)->
          return callback err  if err
          recurly.setBilling "user_#{delegate._id}", data, callback

  @getAccount = secure ({connection:{delegate}}, callback)->
    recurly.getAccount "user_#{delegate._id}", callback

  @getTransactions = secure ({connection:{delegate}}, callback)->
    recurly.getTransactions "user_#{delegate._id}", callback

  @fetchAccount = secure (client, callback)->
    {delegate} = client.connection
    delegate.fetchUser (err, user)->
      return callback err  if err
      {username, firstName, lastName} = delegate.profile
      callback null, {email: user.email, username, firstName, lastName}

  @getBalance_ = (account, callback)->
    recurly.getTransactions account, (err, adjs)->
      spent = 0
      adjs.forEach (adj)->
        spent += parseInt adj.amount, 10  if adj.status is 'success'

      recurly.getAdjustments account, (err, adjs)->
        charged = 0
        adjs.forEach (adj)->
          charged += parseInt adj.amount, 10

        callback null, spent - charged

  @getBalance = secure (client, callback)->
    {delegate} = client.connection
    @getBalance_ "user_#{delegate._id}", callback

  @invalidateCacheAndLoad: (constructor, selector, options, callback)->
    cb = -> constructor.all selector, callback
    return cb()  unless options.forceRefresh

    constructor.one selector, sort:lastUpdate:1, (err, obj)=>
      return constructor.updateCache selector, cb  if err or not obj
      obj.lastUpdate ?= 0
      now = (new Date()).getTime()
      if now - obj.lastUpdate > 1000 * options.forceInterval
        constructor.updateCache selector, cb
      else
        cb()

  @updateCache = (options, callback)->
    {constructor, selector, method, methodOptions, keyField, message, forEach} = options
    selector ?= {}

    console.log "Updating #{message}..."

    cb = (err, objs)->
      return callback err  if err

      all = {}
      all[obj[keyField]] = obj  for obj in objs

      constructor.all selector, (err, cachedObjs)->
        return callback err  if err

        cached = {}
        cached[cObj[keyField]] = cObj  for cObj in cachedObjs

        keys    = all: Object.keys(all), cached: Object.keys(cached)
        stack   = []
        stackCb = (err)-> if err then callback err else stack.fin()

        # remove obsolete plans in mongo
        difference(keys.cached, keys.all).forEach (k)->
          stack.push -> cached[k].remove stackCb

        # create new JRecurlyPlan models for new plans from Recurly
        difference(keys.all, keys.cached).forEach (k)->
          cached[k] = new constructor
          cached[k][keyField] = all[k][keyField]

        keys.all.forEach (k)->
          forEach k, cached[k], all[k], stackCb

        dash stack, ->
          console.log "Updated #{message}!"
          callback()

    if methodOptions
      recurly[method] methodOptions, cb
    else
      recurly[method] cb
