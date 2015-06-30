## OpenResty Javascript challenge
This is a OpenResty Lua and Redis powered puzzle for browsers to mitigate DDOS attacks

### OpenResty Prerequisite
You need cJSON lua module and lua-resty-redis


### How it works
1. Client asks for content, lua asks for cookie
2. Cookie is checked and if valid then pass, if not then ...
3. Lua creates SEED (random string)
4. Lua picks number between 6000 and difficulty
5. Lua creates SHA1 with the number and SHA1
6. Then send the SHA1 and SEED and ask for the number
7. Browser javascript uses forloop to find out the number
8. Javascript sends result and gets back a cookie

### Example OpenResty Site Config
```
# Location of this Lua package
lua_package_path "/opt/lua-resty-rate-limit/lib/?.lua;;";

server {
    listen 80;
    server_name api.dev;

    access_log  /var/log/openresty/api_access.log;
    error_log   /var/log/openresty/api_error.log;

    location / {

      # All keys have default value.
        access_by_lua '
         local puzzle = require "resty.puzzle"
          puzzle.challenge {
            log_level = ngx.INFO,
            cookie_lifetime = 604800
            difficulty = 300000,
            seed_lengt = 30,
            seed_lifetime = 60,
            target = "___",
            cookie_name = "_cuid",
            template = '/location/to/the/puzzle.html',
            client_key = ngx.var.remote_addr,
            redis_config = {
              timeout = 1,
              host = "127.0.0.1",
              port = 6379
            }
          }
        ';

        proxy_set_header  Host               $host;
        proxy_set_header  X-Real-IP          $remote_addr;
        proxy_set_header  X-Forwarded-For    $remote_addr;
        proxy_pass   https://github.com;
    }
    location /__ {
      content_by_lua '
        local puzzle = require "resty.puzzle"
        puzzle.response {
          log_level = ngx.INFO,
          cookie_lifetime = 604800
          difficulty = 300000,
          seed_lengt = 30,
          seed_lifetime = 60,
          target = "___",
          cookie_name = "_cuid",
          template = '/location/to/the/puzzle.html',
          client_key = ngx.var.remote_addr,
          timezone = "GMT",
          http_only_cookie = false,
          cookie_secure = false,
          cookie_domain = ngx.var.host,
          cookie_path = "/",
          min_time = 2,
          redis_config = {
            timeout = 1,
            host = "127.0.0.1",
            port = 6379
          }
        }
      ';
    }
}
```

### Config Values
You can customize the puzzle options by changing the following values:

* key: The value to use as a unique identifier in Redis, COOKIE_ or SEED_ is prepended
* cookie_lifetime: For how long you want the browser and redis to store the cookie?
* difficulty: How many interaction to you want the browser to perform, this is the upper limit of a range
* seed_lengt: How long you want the SEED to be, just for the random string generator
* seed_lifetime: For how long do you want the SEED to be stored in redis
* target: Path for AJAX to request to with answer
* cookie_name : Name of the cookie
* template : Path to the HTML template
* client_key : How do you want to identify users, can be anything, IP is just fine
* timezone : Timezone appended to Set-Cookie Expires
* http_only_cookie : Can the cookie be used with AJAX?
* cookie_secure : HTTPS only cookie?
* cookie_domain : For what domain is the cookie?
* cookie_domain = "/",
* min_time : Minimun time needed before users can send there results
* log_level: Set an Nginx log level. All errors from this plugin will be dumped here
* redis_config: The Redis host, port, timeout and pool size


### Template
There is a demo template with this module, you can use it or edit it..
In the file there are few variables
* ::SEED:: will be replaced for the SEED
* ::HASH:: will be replaced for the expected result sha1 hash
* ::TARGET:: Where the ajax should send the result
* ::URL:: User original URL


### Possible flaws
In theory users can brute force the api with flooding integers, but rate limit should stop that.. easyer just to puzzle :)
