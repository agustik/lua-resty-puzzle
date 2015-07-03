_M = { _VERSION = "1.0" }

local redis = require "resty.redis"
local ck = require "resty.cookie"


local cjson = require "cjson"
local clientIP = ngx.var.remote_addr

local sha1 = require "sha1"

local function CreatePow(min,max)
 math.randomseed(os.time());
 -- Start from 6000, so it wont be to easy
 return math.random(min, max);
end

local function render(template, obj)
    local str = ""
    for key, value in pairs(obj) do
        str = "::" .. key .. "::"
        template = string.gsub(template,str, value)
    end
    return template
end


local function RandomString(length)
   length = length or 1
   if length < 1 then return nil end

    math.randomseed(os.time());
    local chars = "qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM";
    local charlength = string.len(chars);
    local array = {}
         for i = 1, length do
            local rand = math.random(0, charlength)
              array[i] = string.sub(chars,rand, rand + 1);
    end
   return table.concat(array)
end

local function Fetch(redis_connection, key, log_level)
  local json, err = redis_connection:get(key)
  if not json then
     -- ngx.say("failed to get ipaddr ", err)
     ngx.log(log_level, "failed to get key ", err)
     ngx.exit(nginx.HTTP_INTERNAL_SERVER_ERROR)
     return
  end

  if json == ngx.null then
     -- Nothing in the DB, return false
     return nil
  else
    return cjson.decode(json)
  end
end

local function Set(redis_connection, key, data, ttl, log_level)
  ok, err = redis_connection:set(key, cjson.encode(data))
  if not ok then
    ngx.log(log_level, "failed to set key ", err)
    ngx.exit(nginx.HTTP_INTERNAL_SERVER_ERROR)
    return
  end

  -- Set lifetime of key
  ok, err = redis_connection:expire(key, ttl)
  if not ok then
    ngx.log(log_level, "failed to set key expire ", err)
    ngx.exit(nginx.HTTP_INTERNAL_SERVER_ERROR)
    return
  end

  return true
end

function _M.challenge(config)

  local redis_config      = config.redis_config or {}

  -- Basic config, with default values
  local LOG_LEVEL         = config.log_level or ngx.NOTICE

  local COKKIE_LIFETIME   = config.session_lifetime or 604800
  local BASIC_DIFFICULTY  = config.difficulty or 100
  local MIN_DIFFICULTY    = config.min_difficulty or 0
  local SEED_LENGTH       = config.seed_lengt or 30
  local SEED_LIFETIME     = config.lifetime or 60
  local RESPONSE_TARGET   = config.target or "___"
  local COOKIE_NAME       = config.cookie or "_cuid"
  local PUZZLE_TEMPLATE_LOCATION = config.template or '/etc/nginx/html/puzzle.html'
  local CLIENT_KEY        = config.client_key or ngx.var.remote_addr



  -- Redis Config
  local REDIS_TIMEOUT     = redis_config.timeout or 1
  local REDIS_SERVER      = redis_config.host or "127.0.0.1"
  local REDIS_PORT        = redis_config.port or 6379

  local COOKIE_FETCH_KEY = "COOKIE_" .. CLIENT_KEY

  local SEED_FETCH_KEY = "SEED_" .. CLIENT_KEY

  local authenticated = false

  local field = false
  -- Create URL
  local URL = ngx.var.scheme .. "://" .. ngx.var.host .. ngx.var.request_uri;

  local cookie, err = ck:new()
  if not cookie then
     ngx.log(LOG_LEVEL, err)
     ngx.exit(503)
     return
  end

  local REDIS_CONNECTION = redis:new()
  REDIS_CONNECTION:set_timeout(REDIS_TIMEOUT * 1000)

  local ok, error = REDIS_CONNECTION:connect(REDIS_SERVER, REDIS_PORT)
  if not ok then
      ngx.log(LOG_LEVEL, "failed to connect to redis: ", error)
      ngx.exit(503)
      return
  end

  field, err = cookie:get(COOKIE_NAME)
  if field then
    local redis_fetch = Fetch(REDIS_CONNECTION, COOKIE_FETCH_KEY, LOG_LEVEL)
    if redis_fetch ~= nil then
      if redis_fetch == field then
        authenticated = true
        local ok, err = REDIS_CONNECTION:close()
        ngx.header.cache_control = "no-store";
        return true
      end
    end
  end


  if ngx.var.request_method ~= 'GET' then
    if not authenticated then
      --ngx.exit(ngx.HTTP_FORBIDDEN)
          ngx.exit(405)
    end
  end

  -- Set client key for SEED


  local TRYS = 1

  local SEED = ""
  local POW  = ""
  local reuse = false


  local DIFF = BASIC_DIFFICULTY * TRYS

  local redis_fetch = Fetch(REDIS_CONNECTION, SEED_FETCH_KEY, LOG_LEVEL)

  -- If not set in REDIS, then do some work

  local obj = {}

  local now = os.time();

  if redis_fetch == nil then
    SEED = RandomString(30)
    -- Create Proof Of Work integer
    POW=CreatePow(MIN_DIFFICULTY,DIFF);

    -- Create string for SHA1
    local sha1_string = SEED .. POW

    -- SHA1 string
    local HASH = sha1(sha1_string)

    -- Get time NOW in epoch


    obj = {
      POW = POW ,
      SEED = SEED,
      HASH = HASH,
      TRYS = TRYS,
      DIFF = DIFF,
      TIME = now,
      TARGET = RESPONSE_TARGET,
      URL = URL
    }
    -- Set to REDIS, so it can be fetched
    local redis_set = Set(REDIS_CONNECTION, SEED_FETCH_KEY, obj, SEED_LIFETIME, LOG_LEVEL)
  else
    -- Bump trys
    TRYS = tonumber(redis_fetch['TRYS']) + 1

    -- Make it harder
    DIFF = BASIC_DIFFICULTY * TRYS
    obj = {
      POW = redis_fetch['POW'] ,
      SEED = redis_fetch['SEED'],
      HASH = redis_fetch['HASH'],
      TRYS = TRYS,
      DIFF = DIFF,
      TIME = now,
      TARGET = redis_fetch['TARGET'],
      URL = redis_fetch['URL']
    }

    -- Set to REDIS, so trycount we can bump trycount and Time
    local redis_set = Set(REDIS_CONNECTION, SEED_FETCH_KEY, obj, SEED_LIFETIME, LOG_LEVEL)
    --obj = redis_fetch
  end


  -- For debugging , output JSON
  --ngx.say(cjson.encode(obj))


  -- Set template as string
  local PUZZLE_TEMPLATE = ""

  -- Open file
  local f = io.open(PUZZLE_TEMPLATE_LOCATION,'r')


  -- If file not open, then throw error
  if f~=nil then

    -- Read all file
    PUZZLE_TEMPLATE = f:read('*all')
    io.close(f)
    else
    -- Log if error and exit with error code
    ngx.log(LOG_LEVEL, 'Could not find template')
    ngx.exit(503)
  end

  local puzzle_html = render(PUZZLE_TEMPLATE, obj)

  -- Render the template to users
  -- ngx.header["Cache-Control"] = "no-cache, no-store, must-revalidate"
  -- ngx.header["Cache-Control"] = "max-age: 0"
  -- ngx.header["Pragma"] = "no-cache"
  -- ngx.header["Expires"] = "0"

  local ok, err = REDIS_CONNECTION:close()
  ngx.header['Content-Type'] = 'text/html; charset=UTF-8'
  ngx.say(puzzle_html)
  ngx.exit(ngx.HTTP_OK)


   -- ngx.exit(405)
end

function _M.response(config)


  local redis_config      = config.redis_config or {}

  -- Basic config, with default values
  local LOG_LEVEL         = config.log_level or ngx.NOTICE

  local COKKIE_LIFETIME  = config.session_lifetime or 604800
  local BASIC_DIFFICULTY  = config.difficulty or 300000
  local SEED_LENGTH       = config.seed_lengt or 30
  local SEED_LIFETIME     = config.lifetime or 60
  local RESPONSE_TARGET   = config.target or "___"
  local COOKIE_NAME       = config.cookie or "_cuid"
  local PUZZLE_TEMPLATE_LOCATION = config.template or '/etc/nginx/html/puzzle.html'
  local CLIENT_KEY        = config.client_key or ngx.var.remote_addr
  local TIMEZONE          = config.timezone or "GMT"
  local HTTP_ONLY         = config.http_only_cookie or false
  local SECURE            = config.cookie_secure or false
  local COOKIE_DOMAIN     = config.cookie_domain or ngx.var.host
  local COOKIE_PATH       = config.cookie_domain or "/"

  local MIN_TIME          = config.min_time or 2


  -- Redis Config
  local REDIS_TIMEOUT     = redis_config.timeout or 1
  local REDIS_SERVER      = redis_config.host or "127.0.0.1"
  local REDIS_PORT        = redis_config.port or 6379

  -- Ger all args as Lua object
  local args = ngx.req.get_uri_args()

  local SEED = args.SEED
  local POW = tonumber(args.POW)
  local RD_POW = 0
  local TIMEDIFF = 0
  local req_headers = ngx.req.get_headers()
  local COOKIE_EXPIRES = ""
  local COOKIE_VALUE = RandomString(20)

  TIMEZONE = " " .. TIMEZONE

  local now = os.time();

  if not SEED then
    ngx.exit(ngx.HTTP_FORBIDDEN)
    return
  end

  if not POW then
    ngx.exit(ngx.HTTP_FORBIDDEN)
    return
  end

  local COOKIE_FETCH_KEY = "COOKIE_" .. CLIENT_KEY;

  local SEED_FETCH_KEY = "SEED_" .. CLIENT_KEY;

  -- expecting an Ajax GET
  if req_headers.x_requested_with ~= "XMLHttpRequest" then
    ngx.log(ngx.ERR, "Not XMLHttpReq")
    ngx.exit(405)
    return
  end

  ----- Authentication checks done --

  local cookie, err = ck:new()
  if not cookie then
     ngx.log(LOG_LEVEL, err)
     return
  end

  local output = {}

  output.status="fail"
  local REDIS_CONNECTION = redis:new()
  REDIS_CONNECTION:set_timeout(REDIS_TIMEOUT * 1000)

  local ok, error = REDIS_CONNECTION:connect(REDIS_SERVER, REDIS_PORT)
  if not ok then
      ngx.log(LOG_LEVEL, "failed to connect to redis: ", error)
      return
  end


  local redis_fetch = Fetch(REDIS_CONNECTION, SEED_FETCH_KEY, LOG_LEVEL)

  if redis_fetch == nil then
    -- Not found in REDIS. No further proccessing needed
  else
    -- Found, check if valid
    RD_POW = redis_fetch["POW"]

    TIMEDIFF = now - redis_fetch['TIME']

    if (POW == RD_POW) then
      if TIMEDIFF >= MIN_TIME then



        COOKIE_EXPIRES = os.date('%a, %d %b %Y %X', os.time() + COKKIE_LIFETIME ) .. TIMEZONE
        local ok, err = cookie:set({
            key = COOKIE_NAME, value = COOKIE_VALUE, path = COOKIE_PATH,
            domain = COOKIE_DOMAIN, secure = SECURE, httponly = HTTP_ONLY,
            expires = COOKIE_EXPIRES, max_age = COKKIE_LIFETIME
        })

        -- Log to redis with long lifetime
        local redis_set = Set(REDIS_CONNECTION, COOKIE_FETCH_KEY, COOKIE_VALUE, COKKIE_LIFETIME, LOG_LEVEL)
        if redis_set == nil then
          output.message="Server error"
        else
          output.status="success"
          output.redirect=redis_fetch['URL']
        end
        if not ok then
            ngx.log(LOG_LEVEL, err)
            return
        end
      else
        output.message="To fast !"
        output.time = TIMEDIFF
      end

    end

  end

  local ok, err = REDIS_CONNECTION:close()
  ngx.header.cache_control = "no-store";
  -- ngx.header["Cache-Control"] = "no-cache, no-store, must-revalidate"
  -- ngx.header["Cache-Control"] = "max-age: 0"
	-- ngx.header["Pragma"] = "no-cache"
	-- ngx.header["Expires"] = "0"

  --output.data=redis_fetch
  ngx.say(cjson.encode(output))

end


return _M
