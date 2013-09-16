jraphical = require 'jraphical'
recurly   = require 'koding-payment'

forceRefresh  = yes
forceInterval = 60

module.exports = class JRecurlyPlan extends jraphical.Module

  {secure, dash}       = require 'bongo'
  {difference, extend} = require 'underscore'

  JUser                = require '../user'
  JRecurly             = require './index'
  JRecurlyToken        = require './token'
  JRecurlySubscription = require './subscription'

  @share()

  @set
    indexes:
      code         : 'unique'
    sharedMethods  :
      static       : ['getPlans', 'getPlanWithCode']
      instance     : ['getToken', 'getType', 'subscribe', 'getSubscriptions']
    schema         :
      code         : String
      title        : String
      desc         : String
      feeMonthly   : Number
      feeInitial   : Number
      feeInterval  : Number
      product      :
        prefix     : String
        category   : String
        item       : String
        version    : Number
      lastUpdate   : Number

  @getPlans = secure (client, filter..., callback)->
    [prefix, category, item] = filter
    selector = {}
    selector['product.prefix']   = prefix    if prefix
    selector['product.category'] = category  if category
    selector['product.item']     = item      if item

    JRecurly.invalidateCacheAndLoad this, selector, {forceRefresh, forceInterval}, callback

  @getPlanWithCode = (code, callback)-> JRecurlyPlan.one {code}, callback

  getToken: secure (client, data, callback)->
    JRecurlyToken.createToken client, planCode: @code, callback

  doSubscribe = (code, data, callback)->
    data.multiple ?= no

    JRecurlySubscription.getAllSubscriptions {
      userCode
      planCode  : @code
      $or       : [
        {status : 'active'}
        {status : 'canceled'}
      ]
    }, (err, [sub])=>
      return callback err  if err

      if sub
        return callback 'Already subscribed.'  unless data.multiple

        sub.quantity ?= 1
        recurly.updateSubscription userCode,
          quantity : ++subs.quantity
          plan     : @code
          uuid     : subs.uuid
        , (err)=>
          return callback err  if err
          sub.save (err)-> callback err, sub
      else
        recurly.createSubscription userCode, plan: @code, (err, result)->
          return callback err  if err
          {planCode: plan, uuid, quantity, status, datetime, expires, renew, amount} = result
          sub = new JRecurlySubscription {
            userCode, planCode, uuid, quantity, status, datetime, expires, renew, amount
          }
          sub.save (err)-> callback err, sub

  subscribe: secure ({connection:{delegate}}, data, callback)->
    doSubscribe "user_#{delegate._id}", data, callback

  subscribeGroup: (group, data, callback)->
    doSubscribe "group_#{group._id}", data, callback

  getSubscription: secure ({connection:{delegate}}, callback)->
    JRecurlySubscription.one {userCode: "user_#{delegate._id}", planCode: @code}, callback

  getType:-> if @feeInterval is 1 then 'recurring' else 'single'

  getSubscriptions: (callback)->
    JRecurlySubscription.all
      planCode: @code
      $or      : [
        {status: 'active'}
        {status: 'canceled'}
      ]
    , callback

  getOwnerGroup: (callback)->
    if @product.prefix isnt 'groupplan'
      callback null, 'koding'
    else
      JGroup = require '../group'
      JGroup.one _id: @product.category, (err, group)->
        callback err, unless err then group.slug

  @updateCache = (selector, callback)->
    JRecurly.updateCache
      constructor   : this
      method        : 'getPlans'
      keyField      : 'code'
      message       : 'product cache'
      forEach       : (k, cached, plan, stackCb)->
        return stackCb()  unless k.match /^([a-zA-Z0-9-]+_){3}[0-9]+$/
        {title, desc, feeMonthly, feeInitial, feeInterval} = plan
        [prefix, category, item, version] = k.split '_'
        version++

        cached.product = {prefix, category, item, version}
        cached.lastUpdate = (new Date()).getTime()
        cached.setData extend cached.getData(), {title, desc, feeMonthly, feeInitial, feeInterval}
        cached.save stackCb
    , callback
