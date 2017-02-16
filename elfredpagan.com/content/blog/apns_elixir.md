+++
showcomments = true
categories = ["development"]
tags = ["Elixir", "fresh eyes"]
date = "2017-02-15T15:31:01-06:00"
title = "iOS Push Notifications in Elixir"
description = "writing a simple Elixir app to send push notifications"
showpagemeta = true
slug = ""
comments = false

+++

I'm currently playing with Elixir, but I don't have any strong product ideas, so
I'm building generic infrastructure I might need later on. I have solved some of
these problems with other languages, I find rebuilding these things as a good way to
familiarize myself with new languages and frameworks. The first thing I decided
to build out is a push notification service.

I'll mostly focus on using the legacy binary protocol in this implementation.
The repository is available [here](https://github.com/elfredpagan).

## Getting started

The first thing to do is use `mix` to create an Elixir project. I'm using OTP
processes to send the push notifications so we want a supervisor to manage the
these. The command to do this is:

```
% mix new apns --sup
```

This creates a new Elixir application with its own supervisor tree. You can then
add your processes to the children list to have them managed by the supervisor.

```
# lib/apns.ex

defmodule APNS do

  use Application

  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    # Define workers and child supervisors to be supervised
    children = [
      # Starts a worker by calling: APNS.Worker.start_link(arg1, arg2, arg3)
      # worker(APNS.Worker, [arg1, arg2, arg3]),
    ]

    opts = [strategy: :one_for_one, name: APNS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

I am a bit fussy so I capitalized `APNS` in my module names since it is an acronym.

## Creating and reading a configuration

If you want to send a push notification, you need to create a certificate and
key to connect to Apple's service. The docs for this are [here](https://developer.apple.com/library/content/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/BinaryProviderAPI.html). We need a way to configure this in our application. The easiest way
is to use the configuration files mix created.

```
# config/config.exs
use Mix.Config
config :apns, :config,
  push_host: "gateway.sandbox.push.apple.com",
  push_port: 2195,
  cert: "priv/cert.pem",
  key: "priv/key.pem",
  feedback_handler: APNS.FeedbackHandler

```
This defines a keyword list for the APNS application. In it, I specify a few
configuration values: the host, port of the APNS service, the certificate
and key locations and finally a feedback handler module to send back the error
responses.

## Creating the OTP GenServer and managing an SSL connection

I then created the OTP process that will manage our APNS connection and send
out the push notifications. I use the [Connection](https://github.com/fishcakez/connection)
library that extends GenServer to support connecting, disconnecting and backs off
in the case of errors.

The first thing I do is implement `start_link` which is responsible for starting
the process. Here I read the configuration above, create an initial state
map with the connection and SSL options we will use.

```
# lib/push_worker.ex
defmodule APNS.PushWorker do
  use Connection

  # client api
  def start_link(_) do
    config = Application.get_env(:apns, :config)
    host = config[:push_host]
    port = config[:push_port]
    cert_path = config[:cert]
    key_path = config[:key]
    feedback_handler = config[:feedback_handler]
    opts = [
      reuse_sessions: false,
      mode: :binary,
      certfile: to_char_list(cert_path),
      keyfile: to_char_list(key_path),
      active: :once
    ]
    state = %{
      host: to_char_list(host),
      port: port,
      opts: opts,
      timeout: 60 * 1000,
      socket: nil,
      feedback_handler: feedback_handler
    }
    Connection.start_link(__MODULE__, state)
  end

  ...
```
One interesting thing here is that I convert Elixir strings to char lists. We
use Erlang's SSL library and it expects character lists as inputs.

When we call `Connection.start_link` the `init` method gets called back by OTP. I implement
it as follows:
```
def init(state) do
  {:connect, :init, state}
end
```

This then causes the `connect` function to be called. Here I actually make my
socket connection.

```
def connect(_, %{socket: nil, host: host, port: port, opts: opts,
timeout: timeout} = state) do
  case :ssl.connect(host, port, opts, timeout) do
    {:ok, socket} ->
      {:ok, %{state | socket: socket}}
    {:error, reason} ->
      :error_logger.format("Connection error: ~s state: ~s ~n", [reason, inspect(state)])
      {:backoff, 1000, state}
    end
end
```

If I create a connection, I add the socket to the process state. Otherwise
I back off, Connection tries again later. I follow these up with a few other
methods to manage disconnecting and reconnecting as needed depending on errors
and connectivity status. These are not relevant to APNS so you can look at the
repository for more info.

## Creating and transforming the notification object

I then create an Elixir struct to model my notification. I also create a set of
methods to manipulate the fields in it. The file is in [lib/notification.ex](https://github.com/elfredpagan/apns/blob/master/lib/notification.ex) but
the implementation allows us to manipulate a notification as follows:

```
import APNS.Notification
push =
  new()
  |> alert("hello world")
  |> badge(5)
  |> sound("sound.aiff")
  |> category("hello")
  |> mutable_content(true)
  |> thread_id(1)
```

Which I find quite nice. It reminds me of the [builder pattern](https://en.wikipedia.org/wiki/Builder_pattern).
without the .build() call at the end. One important thing to note is that at
every step of the way, we're creating a new notification struct since data is
immutable in Elixir.

## Sending out a notification

Once I have a model object, I need to structure the data to send through the
binary protocol. I create an encoder module to handle this work.

```
# lib/encoder.ex
defmodule APNS.Encoder do

  def encode_notification(token, notification) do
    json = APNS.Notification.to_json(notification)
    frame_data = <<>>
    |> encode_frame_data(1, byte_size(token), token)
    |> encode_frame_data(2, byte_size(json), json)
    |> encode_frame_data(3, 4, notification.identifier)
    |> encode_frame_data(4, 4, notification.expiration_date)
    |> encode_frame_data(5, 1, notification.priority)

    << 2 :: size(8), byte_size(frame_data) :: size(32), frame_data :: binary >>
  end

  # Not sure why I need the clauses with specific sizes.
  # It seems like I can't use dynamic values in a binary size() modifier?

  defp encode_frame_data(frame_data, _id, _size, nil) do
    frame_data
  end

  defp encode_frame_data(frame_data, id, size, data) when is_binary(data) do
    frame_data <> << id :: size(8), size :: size(16), data :: binary >>
  end

  defp encode_frame_data(frame_data, id, 1 = size, data) do
    frame_data <> << id :: size(8), size :: size(16), data :: size(8) >>
  end

  defp encode_frame_data(frame_data, id, 4 = size, data) do
    frame_data <> << id :: size(8), size :: size(16), data :: size(32) >>
  end

end
```

It exports an `encode_notification` function that receives a token in binary
form and the notification object I want to send out. It then constructs
a binary blob. I think this method really shows where Elixir shines. The ease
with which I can append binary data and specify sizes is really nice. Having
multiple function heads also makes it easy to ignore nil data.

I'm a bit unhappy with the last two function heads. For some reason, I couldn't
pass a variable value to the `size()` modifier, so I needed to add function
heads for the sizes I knew about.

Once I can properly encode data, I'm ready to send it out.
```
# lib/push_worker.ex
# client api
def push(pid, token, notification) do
  Connection.call(pid, {:push, token, notification})
end

# server api

def handle_call({:push, token, notification}, _from, %{socket: socket} = state) do
  data = APNS.Encoder.encode_notification(token, notification)
  case :ssl.send(socket, data) do
    :ok ->
      {:reply, :ok, state}
    {:error, reason} = error ->
      reason = :inet.format_error(reason)
      :error_logger.format("connection error: ~s~n", [reason])
      {:disconnect, error, state}
  end
end
```

Here, I just provide a client api method that makes a `call` to the process with
a `push` message. Then in `handle_call` I match against the message and send
the data through the socket and log any errors.

## Handling feedback

Originally, there was a separate feedback socket but I think that has been deprecated
when the newer binary protocol was rolled out. At least I never received any
messages on it in my tests and I receive responses through the push socket
on bad requests. To handle these, I implement `handle_info` functions to received
and parse the data and forward it to the `FeedbackHandler` that is set in the
configuration.

```
  def handle_info({:ssl, socket, _msg}, %{socket: socket, feedback_handler: nil} = state) do
    {:no_reply, state}
  end

  def handle_info({:ssl, socket, << command :: size(8), status :: size(8), identifier :: size(32)>> = msg}, %{socket: socket, feedback_handler: handler} = state) do
    handler.handle_feedback(command, status, identifier)
    {:no_reply, state}
  end
```
The first function handles the case where there isn't a `FeedbackHandler` in our
state and just does nothing. The second implementation parses the message and
passes the deconstructed values to the handler.

## Using poolboy to create a process pool

Now, I want to have a couple of push workers running at once. I use poolboy to
accomplish this. I update my `start` method as follows:

```
# lib/apns.ex
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    pool_options = [
     name: {:local, :apns_pool},
     worker_module: APNS.PushWorker,
     size: 5,
     max_overflow: 2
   ]

    children = [
      :poolboy.child_spec(:apns_pool, pool_options, [])
    ]

    opts = [strategy: :one_for_one, name: APNS.Supervisor]
    Supervisor.start_link(children, opts)
  end
```


## Providing a client API

Then, all that is left is to provide an API for clients to use. This turns out
to be fairly straightforward.

```
def push(token, notification) do
  :poolboy.transaction(:apns_pool, fn(worker)->
      APNS.PushWorker.push(worker, token, notification)
    end)
end
```

This just checks out a worker using poolboy and calls the push client method
on it.

## What did I find interesting?

Elixir is pretty fun to work with and departure from my day to day. Here are a
few of the things I found curious.

### Pattern matching and destructuring

Matching and destructuring your inputs in function heads or on return is a pretty
interesting concept. The idea of having multiple implementations depending on your
input is nice as well. You end up writing a lot less if statements because of this
and you don't pollute the code that does the work with early return statements based
on input validity.

### Interfacing with Erlang

Interop between "newer" languages built on top of older VMs is always a bit jank.
Elixir and Erlang are not that different. You need to prefix Erlang modules with
`:` and most Erlang modules expect character lists instead of "Strings" (which
  are just UTF binaries). Overall, the process is fairly seamless, but it's obvious
  you are munging things to interop with something else. This bit me the most
  when I was starting to try out http/2 libs for my other implementation.

### Working with Binaries

Working with binaries in Elixir is nothing short of magic. The ease with which
you can create and read binary data is seriously impressive. It truly beats managing
an array of bytes.

### Immutability

I've worked with immutable model layers before, but that is the only option in
Elixir. Having to reassign to a variable can get a bit cumbersome sometimes, but
I do think it's worth it. I think if Elixir forces single assignment like Erlang,
this would get tedious. The `|>` operator does help with cutting intermediate
assigns while you transform your data set.

## Aside: Push Notifications through HTTP/2

I also implemented an HTTP/2 version of APNS. For this I used
[Gun](https://github.com/ninenines/gun) as an HTTP/2 client and [Joken](https://github.com/bryanjos/joken)
to generate JSON Web Tokens. The sad thing is that I had to use the git version
of Gun, which requires newer versions of cowlib and ranch. This conflicts with
the current versions used in Phoenix, so I can't use my APNS server in a Phoenix
application. I have to figure out what options I have here.
