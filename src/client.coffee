# Represents a user accessing the application.
class DropboxClient
  # Dropbox client representing an application.
  #
  # For an optimal user experience, applications should use a single client for
  # all Dropbox interactions.
  #
  # @param {Object} options the application type and API key
  # @option {Boolean} sandbox true for applications that request sandbox access
  #     (access to a single directory exclusive to the app)
  # @option {String} key the application's API key
  # @option {String} secret the application's API secret
  # @option {String} token if set, the user's access token
  # @option {String} tokenSecret if set, the secret for the user's access token
  # @option {String} uid if set, the user's Dropbox UID
  constructor: (options) ->
    @sandbox = options.sandbox or false
    @oauth = new DropboxOauth options
    @uid = options.uid or null

    @apiServer = options.server or 'https://api.dropbox.com'
    @authServer = options.authServer or @apiServer.replace('api.', 'www.')
    @fileServer = options.fileServer or
                    @apiServer.replace('api.', 'api-content.')
    
    @setupUrls()

  # Plugs in the authentication driver.
  #
  # @param {String} url the URL that will be used for OAuth callback; the
  #     application must be able to intercept this URL and obtain the query
  #     string provided by Dropbox
  # @param {function(String, function(String))} driver the implementation of
  #     the authorization flow; the function should redirect the user to the
  #     URL received as the first argument, wait for the user to be redirected
  #     to the URL provded to authCallback, and then call the supplied function
  #     with
  authDriver: (url, driver) ->
    @authDriverUrl = url
    @authDriver = driver

  # OAuth credentials.
  #
  # @return {Object} a plain object whose properties can be passed to the
  #     Dropbox.Client constructor to reuse this client's login credentials
  credentials: ->
    value =
      key: @oauth.key
      secret: @oauth.secret
    if @oauth.token
      value.token = @oauth.token
      value.tokenSecret = @oauth.tokenSecret
      value.uid = @uid
    value
      
  # Authenticates the app's user to Dropbox' API server.
  #
  # @param {function(String, String)} callback called when the authentication
  #     completes; if successful, the first argument is the user's Dropbox
  #     user id, which is guaranteed to be consistent across API calls from the
  #     same application (not across applications, though); if an error occurs,
  #     the first argument is null and the second argument is an error string;
  #     the error is suitable for logging, but not for presenting to the user,
  #     as it is not localized
  authenticate: (callback) ->
    @requestToken (data, error) =>
      if error
        callback null, error
        return
      token = data.oauth_token
      tokenSecret = data.oauth_token_secret
      @oauth.setToken token, tokenSecret
      @authDriver @authorizeUrl(token), (url) =>
        @getAccessToken (data, error) =>
          if error
            @reset()
            callback null, error
            return
          token = data.oauth_token
          tokenSecret = data.oauth_token_secret
          @oauth.setToken token, tokenSecret
          @uid = data.uid
          callback data.uid

  # Retrieves the contents of a file stored in Dropbox.
  #
  # @param {String} path the path of the file to be read, relative to the
  #     user's Dropbox or to the application's folder
  # @param {Object?} options the advanced settings below; for the default
  #     settings, skip the argument or pass null
  # @option options {Number} version the desired revision (version number) of
  #      the file; the default gets the most recent version
  # @param {function(String, String)} callback called with the result of the
  #     API call; 
  readFile: (path, options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    path = @normalizePath path
    url = "#{@urls.getFile}/#{path}"
    params = {}
    if options
      if options.version?
        params.rev = options.version
    @oauth.addAuthParams 'GET', url, params
    DropboxXhr.request 'GET', url, params, null, callback

  # Store a file into a user's Dropbox.
  #
  # @param {String} path the path of the file to read, relative to the user's
  #     Dropbox or to the application's folder
  # @param {Object?} options the advanced settings below; for the default
  #     settings, skip the argument or pass null
  # @param {Number?} lastVersion the version of the file that was last read
  #     by this program; this is used for conflict resolution
  # @option options {Boolean} noOverwrite if set, the write will not overwrite
  #      a file with the same name that already exsits; instead a new file name
  # @param {Binary} data the file's contents
  #     being edited)
  # @param {function(data, error)} callback called with the result to the
  #     /files (GET) HTTP request. 
  writeFile: (path, data, options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null

    slashIndex = path.lastIndexOf '/'
    if slashIndex is -1
      fileName = path
      path = ''
    else
      fileName = path.substring slashIndex
      path = path.substring 0, slashIndex

    path = @normalizePath path
    url = "#{@urls.postFile}/#{path}"
    params = { file: fileName }
    if options
      if options.noOverwrite
        params.overwrite = 'false'
      if options.lastVersion?
          params.parent_rev = options.lastVersion
    # TODO: locale support would edit the params here
    @oauth.addAuthParams 'POST', url, params
    # NOTE: the Dropbox API docs ask us to replace the 'file' parameter after
    #       signing the request; the code below works as intended
    delete params.file
    
    fileField =
      name: 'file',
      value: data,
      fileName: fileName
      contentType: 'application/octet-stream'
    DropboxXhr.multipartRequest url, fileField, params, null, callback

  # @param {String} path to the file you want to retrieve
  # @param {Number} file_limit on the number of files listed. Defaults to
  # 10,000, max is 25,000.
  # @param {String} hash field of the last call to /metadata (on this folder). If
  #     nothing has changed since the last call, the response will be a 304
  #     (not modified) status code
  # @param {Boolean} list
  # @param {Boolean} include_deleted
  # @param {Number} rev
  # @param {String} locale
  # @param {function(data, error)} callback called with the result to the
  #     /files (GET) HTTP request. 
  metadata: (path, fileLimit, hash, list, includeDeleted, rev, locale, callback) ->
    path = @normalizePath path
    url = "#{@urls.metadata}/#{path}"  
    params = {}
    if fileLimit?
        params['file_limit'] = fileLimit
    if hash?
        params['hash'] = hash
    if list?
        params['list'] = list
    if includeDeleted?
        params['include_deleted'] = includeDeleted
    if rev?
        params['rev'] = rev
    if locale?
        params['locale'] = locale
    @oauth.addAuthParams 'GET', url, params
    DropboxXhr.request 'GET', url, params, null, callback

  # @param {function(data, error)} callback called with the result to the
  #     /files (GET) HTTP request. 
  delta: (cursor, locale, callback) ->
    url = @urls.delta
    params = {}
    if cursor?
        params['cursor'] = cursor
    if locale?
        params['locale'] = locale
    @oauth.addAuthParams 'POST', url, params
    DropboxXhr.request 'POST', url, params, null, callback

  # @param {String} root relative to which path is specified. Valid values
  #     are 'sandbox' and 'dropbox'
  # @param {String} path to the file you want to retrieve
  # @param {function(data, error)} callback called with the result to the
  #     /files (GET) HTTP request. 
  revisions: (path, revLimit, locale, callback) ->
    path = @normalizePath path
    url = "#{@urls.revisions}/#{path}"
    params = {}
    if revLimit?
        params['rev_limit'] = revLimit
    if locale?
        params['locale'] = locale
    @oauth.addAuthParams 'GET', url, params
    DropboxXhr.request 'GET', url, params, null, callback
    
  # @param {String} root relative to which path is specified. Valid values
  #     are 'sandbox' and 'dropbox'
  # @param {String} path to the file you want to retrieve
  # @param {function(data, error)} callback called with the result to the
  #     /files (GET) HTTP request. 
  restore: (path, rev, locale, callback) ->
    path = @normalizePath path
    url = "#{@urls.restore}/#{path}"
    params = {}
    if rev?
        params['rev'] = rev
    if locale?
        params['locale'] = locale
    @oauth.addAuthParams 'GET', url, params
    DropboxXhr.request 'GET', url, params, null, callback

  # @param {String} root relative to which path is specified. Valid values
  #     are 'sandbox' and 'dropbox'
  # @param {String} path to the file you want to retrieve
  # @param {function(data, error)} callback called with the result to the
  #     /files (GET) HTTP request. 
  search: (path, query, fileLimit, includeDeleted, locale, callback) ->
    path = @normalizePath path
    url = "#{@urls.search}/#{path}"
    params = {query: query}
    if fileLimit?
        params['file_limit'] = fileLimit
    if includeDeleted?
        params['include_deleted'] = includeDeleted
    if locale?
        params['locale'] = locale
    @oauth.addAuthParams 'GET', url, params
    DropboxXhr.request 'GET', url, params, null, callback

  # @param {String} root relative to which path is specified. Valid values
  #     are 'sandbox' and 'dropbox'
  # @param {String} path to the file you want to retrieve
  # @param {function(data, error)} callback called with the result to the
  #     /files (GET) HTTP request. 
  shares: (path, locale, shortUrl, callback) ->
    path = @normalizePath path
    url = "#{@urls.shares}/#{path}"
    params = {}
    if locale?
        params['locale'] = locale
    if shortUrl?
        params['short_url'] = shortUrl
    @oauth.addAuthParams 'POST', url, params
    DropboxXhr.request 'POST', url, params, null, callback

  # @param {String} root relative to which path is specified. Valid values
  #     are 'sandbox' and 'dropbox'
  # @param {String} path to the file you want to retrieve
  # @param {function(data, error)} callback called with the result to the
  #     /files (GET) HTTP request. 
  media: (path, locale, callback) ->
    path = @normalizePath path
    url = "#{@urls.media}/#{path}"
    params = {}
    if locale?
        params['locale'] = locale
    @oauth.addAuthParams 'POST', url, params
    DropboxXhr.request 'POST', url, params, null, callback

  # @param {String} root relative to which path is specified. Valid values
  #     are 'sandbox' and 'dropbox'
  # @param {String} path to the file you want to retrieve
  # @param {function(data, error)} callback called with the result to the
  #     /files (GET) HTTP request. 
  copyRef: (path, callback) ->
    path = @normalizePath path
    url = "#{@urls.copyRef}/#{path}"
    params = {}
    @oauth.addAuthParams 'GET', url, params
    DropboxXhr.request 'GET', url, params, null, callback

  # @param {String} root relative to which path is specified. Valid values
  #     are 'sandbox' and 'dropbox'
  # @param {String} path to the file you want to retrieve
  # @param {function(data, error)} callback called with the result to the
  #     /files (GET) HTTP request. 
  thumbnails: (path, format, size, callback) ->
    path = @normalizePath path
    url = "#{@urls.thumbnails}/#{path}"
    params = {}
    if format?
        params['format'] = format
    if size?
        params['size'] = size
    @oauth.addAuthParams 'GET', url, params
    DropboxXhr.request 'GET', url, params, null, callback

  # Creates a folder in a user's Dropbox.
  #
  # @param {String} path the path of the folder that will be created, relative
  #     to the user's Dropbox or to the application's folder
  # @param {function(Object?, String?)} callback called with the result to the
  #     /fileops/create_folder HTTP request; the result is a stat of the
  #     folder; if the call fails, the second argument is a string containing
  #     the error
  mkdir: (path, callback) ->
    url = @urls.fileopsCreateFolder
    params = { root: @fileRoot, path: @normalizePath(path) }
    @oauth.addAuthParams 'POST', url, params
    DropboxXhr.request 'POST', url, params, null, callback

  # Removes a file or diretory from a user's Dropbox.
  #
  # @param {String} path the path of the file to be read, relative to the
  #     user's Dropbox or to the application's folder
  # @param {function(Object?, String?)} callback called with the result to the
  #     /fileops/delete HTTP request; the result is a stat of the deleted
  #     folder; if the call fails, the second argument is a string containing
  #     the error
  remove: (path, callback) ->
    url = @urls.fileopsDelete
    params = { root: @fileRoot, path: @normalizePath(path)  }
    @oauth.addAuthParams 'POST', url, params
    DropboxXhr.request 'POST', url, params, null, callback

  # Copies a file or directory in the user's Dropbox.
  #
  # This method's "from" parameter can be either a path or a copy reference
  # obtained by a previous call to makeCopyRef. The method uses a crude
  # heuristic to interpret the "from" string -- if it doesn't contain any
  # slash (/) or dot (.) character, it is assumed to be a copy reference. The
  # easiest way to work with it is to prepend "/" to every path passed to the
  # method. The method will process paths that start with multiple /s
  # correctly.
  #
  # @param {String} from the path of the file or folder that will be copied,
  #     or a reference obtained by calling makeCopyRef; if this is a path, it
  #     is relative to the user's Dropbox or to the application's folder
  # @param {String} toPath the path that the file or folder will have after
  #     the method call; the path is relative to the user's Dropbox or to the
  #     application folder
  # @param {Object?} options the advanced setting below
  # @option options {Boolean} copyRef if present, overrides the copy reference
  #     detection heuristic; the value is used directly to decide how to
  # @param {function(Object?, String?)} callback called with the result to the
  #     /fileops/copy HTTP request; the result is a stat of the file or
  #     directory created by the copy operation; if the call fails, the second
  #     argument is a string containing the error
  copy: (from, toPath, options, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null
    
    if options and options.copyRef?
      copyRefOption = true
      forceCopyRef = options.copyRef
    else
      copyRefOption = false
      forceCopyRef = false
    
    params = { root: @fileRoot, to_path: @normalizePath(toPath) }
    if forceCopyRef or (not copyRefOption and @isCopyRef(from))
      params.from_copy_ref = from
    else
      params.from_path = @normalizePath from
    # TODO: locale support would edit the params here

    url = @urls.fileopsCopy
    @oauth.addAuthParams 'POST', url, params
    DropboxXhr.request 'POST', url, params, null, callback

  # Moves a file or directory to a different location in a user's Dropbox.
  #
  # @param {String} fromPath the path of the file or folder that will be moved,
  #     relative to the user's Dropbox or to the application's folder
  # @param {String} toPath the path that the file or folder will have after
  #     the method call; the path is relative to the user's Dropbox or to the
  #     application's folder
  # @param {function(data, error)} callback called with the result to the
  #     /files (GET) HTTP request. 
  move: (fromPath, toPath, callback) ->
    if (not callback) and (typeof options is 'function')
      callback = options
      options = null
    
    fromPath = @normalizePath fromPath
    toPath = @normalizePath toPath
    url = @urls.fileopsMove
    params = {root: @fileRoot, from_path: fromPath, to_path: toPath}
    @oauth.addAuthParams 'POST', url, params
    DropboxXhr.request 'POST', url, params, null, callback

  # Removes all login information.
  #
  # @return {Dropbox.Client} this, for easy call chaining
  reset: ->
    @uid = null
    @oauth.setToken null, ''
    @

  # Computes the URLs of all the Dropbox API calls.
  #
  # @private
  # This is called by the constructor, and used by the other methods. It should
  # not be used directly.
  setupUrls: ->
    @fileRoot = if @sandbox then 'sandbox' else 'dropbox'
    
    @urls = 
      # Authentication.
      requestToken: "#{@apiServer}/1/oauth/request_token"
      authorize: "#{@authServer}/1/oauth/authorize"
      accessToken: "#{@apiServer}/1/oauth/access_token"
      
      # Accounts.
      accountInfo: "#{@apiServer}/1/account/info"
      
      # Files and metadata.
      getFile: "#{@fileServer}/1/files/#{@fileRoot}"
      postFile: "#{@fileServer}/1/files/#{@fileRoot}"
      putFile: "#{@fileServer}/1/files_put/#{@fileRoot}"
      metadata: "#{@apiServer}/1/metadata/#{@fileRoot}"
      delta: "#{@apiServer}/1/delta"
      revisions: "#{@apiServer}/1/revisions/#{@fileRoot}"
      restore: "#{@apiServer}/1/restore/#{@fileRoot}"
      search: "#{@apiServer}/1/search/#{@fileRoot}"
      shares: "#{@apiServer}/1/shares/#{@fileRoot}"
      media: "#{@apiServer}/1/media/#{@fileRoot}"
      copy_ref: "#{@apiServer}/1/copy_ref/#{@fileRoot}"
      thumbnails: "#{@fileServer}/1/thumbnails/#{@fileRoot}"
      
      # File operations.
      fileopsCopy: "#{@apiServer}/1/fileops/copy"
      fileopsCreateFolder: "#{@apiServer}/1/fileops/create_folder"
      fileopsDelete: "#{@apiServer}/1/fileops/delete"
      fileopsMove: "#{@apiServer}/1/fileops/move" 

  # Normalizes a Dropbox path for API requests.
  #
  # @private
  # This is an internal method. It is used by all the client methods that take
  # paths as arguments.
  #
  # @param {String} path a path 
  normalizePath: (path) ->
    if path.substring(0, 1) is '/'
      i = 1
      while path.substring(i, i + 1) is '/'
        i += 1
      path.substring i
    else
      path

  # Heuristic for figuring out whether a string is a path or a copyref.
  #
  # @private
  # This is an internal method. It is used by all the client methods that can
  # take either a path or a copyRef as an argument.
  #
  # @param
  isCopyRef: (pathOrCopyRef) ->
    pathOrCopyRef.indexOf('/') is -1 and pathOrCopyRef.indexOf('.') is -1

  # Really low-level call to /oauth/request_token
  #
  # @private
  # This a low-level method called by authorize. Users should call authorize.
  #
  # @param {function(data, error)} callback called with the result to the
  #    /oauth/request_token HTTP request
  requestToken: (callback) ->
    params = @oauth.addAuthParams 'POST', @urls.requestToken, {}
    DropboxXhr.request 'POST', @urls.requestToken, params, null, callback
  
  # The URL for /oauth/authorize, embedding the user's token.
  #
  # @private
  # This a low-level method called by authorize. Users should call authorize.
  #
  # @param {String} token the oauth_token obtained from an /oauth/request_token
  #     call
  # @return {String} the URL that the user's browser should be redirected to
  #     in order to perform an /oauth/authorize request
  authorizeUrl: (token) ->
    params = { oauth_token: token, oauth_callback: @authDriverUrl }
    "#{@urls.authorize}?" + DropboxXhr.urlEncode(params)

  # Exchanges an OAuth request token with an access token.
  #
  # @private
  # This a low-level method called by authorize. Users should call authorize.
  #
  # @param {function(data, error)} callback called with the result to the
  #    /oauth/access_token HTTP request
  getAccessToken: (callback) ->
    params = @oauth.addAuthParams 'POST', @urls.accessToken, {}
    DropboxXhr.request 'POST', @urls.accessToken, params, null, callback


