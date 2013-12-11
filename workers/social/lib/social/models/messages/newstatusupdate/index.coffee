JPost = require '../post'
{extend} = require 'underscore'
module.exports = class JNewStatusUpdate extends JPost
  {secure, race, signature} = require 'bongo'
  {Relationship} = require 'jraphical'
  {permit} = require '../../group/permissionset'
  {once, extend} = require 'underscore'

  @trait __dirname, '../../../traits/grouprelated'

  @share()

  schema = extend {}, JPost.schema, {
    link :
      link_url   : String
      link_embed : Object
  }

  @set
    slugifyFrom       : 'body'
    sharedEvents      :
      instance        : [
        { name: 'TagsUpdated' }
        { name: 'ReplyIsAdded' }
        { name: 'LikeIsAdded' }
        { name: 'updateInstance' }
        { name: 'RemovedFromCollection' }
        { name: 'PostIsDeleted' }
        { name: 'PostIsCreated'}
      ]
      static          : [
        { name: 'updateInstance' }
        { name: 'RemovedFromCollection' }
      ]
    sharedMethods     :
      static          :
        create:
          (signature Object, Function)
        one:
          (signature Object, Function)
        fetchDataFromEmbedly: [
          (signature String, Object, Function)
          (signature [String], Object, Function)
        ]
        updateAllSlugs: [
          (signature Function)
          (signature Object, Function)
        ]
        fetchFollowingFeed: [
          (signature Function)
          (signature Object, Function)
        ]
        fetchTopicFeed: [
          (signature Function)
          (signature Object, Function)
        ]
        fetchProfileFeed: [
          (signature Function)
          (signature Object, Function)
        ]
        fetchGroupActivity: [
          (signature Function)
          (signature Object, Function)
        ]

      instance        :
        reply:
          (signature String, Function)
        restComments: [
          (signature Function)
          (signature Number, Function)
        ]
        commentsByRange: [
          (signature Function)
          (signature Object, Function)
        ]
        like:
          (signature Function)
        fetchLikedByes: [
          (signature Function)
          (signature Object, Function)
        ]
        mark: [
          (signature String)
          (signature String, Function)
        ]
        unmark: [
          (signature String)
          (signature String, Function)
        ]
        fetchTags: [
          (signature Function)
          (signature Object, Function)
        ]
        delete:
          (signature Function)
        modify:
          (signature Object, Function)
        fetchRelativeComments:
          (signature Object, Function)
        checkIfLikedBefore:
          (signature Function)

    schema            : schema
    relationships     : JPost.relationships

  constructor:->
    super
    @notifyGroupWhen 'LikeIsAdded', 'PostIsCreated'

  @getActivityType =-> require './statusactivity'

  @fetchDataFromEmbedly = (urls, options, callback)->

    urls = [urls]  unless Array.isArray urls

    Embedly = require "embedly"
    {apiKey} = KONFIG.embedly
    new Embedly key: apiKey, (err, api)->
      return callback err if err

      options = extend
        maxWidth: 150
      , options

      options.urls = urls
      api.extract options, callback

  @create = secure (client, data, callback)->
    statusUpdate  =
      meta        : data.meta
      title       : data.title
      body        : data.body
      group       : data.group

    if data.link_url and data.link_embed
      statusUpdate.link =
        link_url   : data.link_url
        link_embed : data.link_embed

    JPost.create.call this, client, statusUpdate, callback

  modify: secure (client, data, callback)->
    statusUpdate =
      meta        : data.meta
      title       : data.title
      body        : data.body

    if data.link_url and data.link_embed
      statusUpdate.link =
        link_url   : data.link_url
        link_embed : data.link_embed

    JPost::modify.call this, client, statusUpdate, callback

  reply: permit 'reply to posts',
    success:(client, comment, callback)->
      JComment = require '../comment'
      JPost::reply.call this, client, JComment, comment, callback

  @getCurrentGroup: (client, callback)->
    groupName = client.context.group or "koding"
    JGroup = require '../../group'
    JGroup.one slug : groupName, (err, group)=>
      if err then return callback err
      unless group then return callback {error: "Group not found"}

      # this is not a security hole
      # everybody can read koding activity feed
      return callback null, group if groupName is "koding"

      # if group is not koding check for security
      {delegate} = client.connection
      return callback {error: "Request not valid"} unless delegate
      group.canReadActivity client, (err, res)->
        if err then return callback {error: "Not allowed to open this group"}
        else callback null, group


  @fetchGroupActivity$ = secure (client, options = {}, callback)->
    @fetchGroupActivity client, options, callback

  @fetchGroupActivity = (client, options = {}, callback)->
    @getCurrentGroup client, (err, group)=>
      if err then return callback err
      {to} = options
      to = if to then new Date(to)  else new Date()
      selector = {'meta.createdAt' : "$lt" : to }

      options.sort = 'meta.createdAt' : -1
      options.limit or= 20
      @some selector, options, (err, data)=>
        return callback err if err
        @decorateResults data, callback

  @fetchProfileFeed = secure (client, options = {}, callback)->
    {connection:{delegate}, context:{group}} = client
    return callback new Error "Origin is not defined" unless options.originId

    {to} = options
    to = if to then new Date(to)  else new Date()

    selector =
      originId        : options.originId
      group           : group
      "meta.createdAt": "$lt": to

    feedOptions =
      sort  : 'meta.createdAt' : -1
      limit : Math.min options.limit ? 20, 20

    @some selector, feedOptions, (err, data)=>
      return callback err if err
      @decorateResults data, callback

  @fetchTopicFeed = secure (client, options = {}, callback)->

    {context:{group}} = client

    JTag = require '../../tag'
    JTag.one { slug : options.slug }, (err, tag)=>
      return callback err  if err
      return callback null, [] unless tag

      {to} = options
      to = if to then new Date(to)  else new Date()

      fetchOptions =
        sort : {'timestamp': -1}
        limit: options.limit or 20

      tag.fetchContents {
        targetName: 'JNewStatusUpdate'
        "timestamp": "$lt": to
      }, fetchOptions, (err, posts)=>
        return callback err if err
        @decorateResults posts, callback

  @fetchFollowingFeed = secure (client, options = {}, callback)->
    {Activity} = require "../../graph"
    options.client = client
    Activity.fetchFolloweeContentsForNewKoding options, (err, ids)=>
      return callback err  if err
      activityIds = ids.map (activity)-> activity.id
      selector =
        _id : "$in" : activityIds
      @some selector, {}, (err, activities)=>
        return callback err  if err
        @decorateResults activities, callback

  @fetchActivitiesWithRels = ({selector, options, relSelector, relOptions}, callback)->
    Relationship.some relSelector, relOptions, (err, rels)=>
      return callback err  if err
      return callback null, [] if not rels or rels.length < 1
      activityIds = rels.map (rel)-> rel.targetId
      selector._id = "$in" : activityIds
      @some selector, options, (err, activities)=>
        return callback err  if err
        @decorateResults activities, callback

  @decorateResults = (posts, callback) ->
    return callback null, [] if not posts or posts.length < 1
    teasers = []
    collectTeasers = race (i, root, fin)->
      root.fetchTeaser (err, teaser)->
        if err
          callback err
          fin()
        else
          teasers[i] = teaser
          fin()
    , -> callback null, teasers
    collectTeasers post for post in posts
