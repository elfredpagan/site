+++
showpagemeta = true
comments = false
categories = ["development"]
tags = ["Elixir", "Alexa"]
date = "2017-02-26T17:44:12-06:00"
title = "Alexa skills with Elixir"
description = "How to write an API to develop Alexa Skills"
showcomments = true

+++

As I delve into working with Elixir and Phoenix, I decided to write an Alexa
Skill. The first thing I needed was a nice api to do so, so I wrote that.

## Modeling the Alexa Request and Response

The first thing I did is write Elixir structs for the Alexa response and request
objects. I like knowing the shape of my data ahead of time and the dot syntax is
more concise than a map access. This step is fairly easy.

### JSON Decoders for the nested objects.
I had to write custom Poison decoders to be able to provide deep parsing/typing
of my structs. Overall, it's fairly straightforward. Here's a sample:

```Elixir
defmodule Alexa.RequestBody do
  defstruct [:version, :session, :context, :request]

  defimpl Poison.Decoder, for: Alexa.RequestBody do
    def decode(data, options) do
      data
      |> Map.update!(:session, fn session ->
        Poison.Decode.decode(session, Keyword.merge(options, as: %Alexa.Session{}))
      end)
      |> Map.update!(:request, fn request ->
        Poison.Decode.decode(request, Keyword.merge(options, as: %Alexa.Request{}))
      end)
      |> Map.update!(:context, fn context ->
        Poison.Decode.decode(context, Keyword.merge(options, as: %Alexa.Context{}))
      end)
    end
  end
end
```

We simply update the keys where we want typed structs.

## Request validation

If you ever want to ship an Alexa Skill, there are a few things you need to do to
ensure that the request is valid and coming from Amazon. If any of these fail,
the request should fail. If I understand Phoenix's design, the correct way to
implement this behavior is through plugs. I wrote some small plugs to handle each of the validation bits.

### Verifying the signature

I said that most of the validations are plugs, well, that is mostly true. plug
lets you read the body data only once, and we need to read it during parsing. That's
why signature verification is implemented as a plug parser. It's also the most
complex of these validations. Lets dig into it.

You verify the signature using the `signature` an `signaturecertchainurl` headers.
`signaturecertchainurl` has the certificate chain that you use to verify that
`signature` is signed by the server. I used an OTP process to handle certificate
validation, since I wanted to cache certificates and OTP processes can have state.
Here is my `handle_call` function.

```Elixir
def handle_call({:validate, chain_uri, signature, body}, _from, state) do
    if uri_from_amazon?(chain_uri) do
      case validate_certificates(chain_uri, state[chain_uri]) do
        {:ok, certificates} ->
          state = Map.put(state, chain_uri, certificates)
          [ certificate | _] = certificates

          case is_signature_valid?(certificate, signature, body) do
            {:ok} ->
              {:reply, :ok, state}
            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_amazon}, state}
    end
  end
```

The first step of this validation is to confirm that the url in
`signaturecertchainurl` is from Amazon. This is fairly easy:

```elixir
defp uri_from_amazon?(uri) do
  uri = URI.parse(uri)
  uri.scheme == "https" && uri.host == "s3.amazonaws.com" && (uri.port == nil || uri.port == 443) && String.starts_with?(uri.path, "/echo.api")
end
```

If the URL is from Amazon, you need to ensure that the certificate chain isn't
expired. This is done by `validate_certificates` which receives the `chain_uri`
or the cached certificates.

```Elixir
def validate_certificates(chain_uri, nil) do
    case HTTPoison.get(chain_uri) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        certificates = :public_key.pem_decode(body)
        |> decoded_certs
        validate_certificates(chain_uri, certificates)
      {_, _} ->
        {:error, :no_cert}
    end
  end

  def validate_certificates(_chain_uri, certificates) do
    certificates
    |> valid_chain?
  end
```

Here, if we don't have cached certificates, we fetch the certificate and
decode them using the `public_key` module. If we have certificates,
we verify that the chain is valid.

#### Down to Erlang

In order to read the certificates, I needed to use Erlang's public key library.
I spent quite a bit of time figuring out how to properly read out the certificates.
This is where I discovered Erlang Records. Wow. They are basically tagged tuples.
Elixir provides the Record module to help interact with these.

This is how you use the Record module.
```Elixir
defmodule Alexa.Records do
  require Record
  import Record
  defrecord :certificate, :OTPCertificate, extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  defrecord :tbs_certificate, :OTPTBSCertificate, extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  defrecord :signature_algorithm, :SignatureAlgorithm, extract(:SignatureAlgorithm, from_lib: "public_key/include/public_key.hrl")
  defrecord :public_key_algorithm, :PublicKeyAlgorithm, extract(:PublicKeyAlgorithm, from_lib: "public_key/include/public_key.hrl")
  defrecord :attribute, :AttributeTypeAndValue, extract(:AttributeTypeAndValue, from_lib: "public_key/include/public_key.hrl")
  defrecord :subject_public_key_info, :OTPSubjectPublicKeyInfo, extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  defrecord :extension, :Extension, extract(:Extension, from_lib: "public_key/include/public_key.hrl")
  defrecord :validity, :Validity, extract(:Validity, from_lib: "public_key/include/public_key.hrl")
end
```

`defrecord` is a macro that generates methods with the tag you specify and you
use those methods to set/get values of an Erlang record as follows.

```Elixir
Alexa.Records.certificate(tbsCertificate: tbsCertificate) = cert
Alexa.Records.tbs_certificate(validity: v) = tbsCertificate
Alexa.Records.validity(notBefore: before) = v
Alexa.Records.validity(notAfter: until) = v
```

Frankly, I find this non-idiomatic, since you can't really create a pipe that
chains record accesses.

#### Verifying the chain

Once I learned of records, validating the chain was easy. we just
reduce the certificate list, verifying that Today is within the validity range.
I used Timex to parse out the ASN.1 dates.

```Elixir
defp valid_chain?(decoded_certs) do
  valid_chain = Enum.reduce(decoded_certs, true, fn(cert, acc) ->
    Alexa.Records.certificate(tbsCertificate: tbsCertificate) = cert
    Alexa.Records.tbs_certificate(validity: v) = tbsCertificate
    Alexa.Records.validity(notBefore: before) = v
    Alexa.Records.validity(notAfter: until) = v
    {_, not_before} = before
    {_, not_after} = until
    {:ok, not_before} = Timex.parse("#{not_before}", "{ASN1:UTCtime}")
    {:ok, not_after} = Timex.parse("#{not_after}", "{ASN1:UTCtime}")
    now = DateTime.utc_now
    acc && (DateTime.compare(not_before, now) == :lt && DateTime.compare(now, not_after) == :lt)
  end)
  if valid_chain do
    {:ok, decoded_certs}
  else
    {:error, :invalid_chain}
  end
end
```

If the certificates are valid, we add them to the state, using the uri as the key.
We now go on to verify the signature. Step 1. here is to verify that the certificate
is from Amazon. We do this by reading the dNSName entry of the record and
comparing it with a predefined value.

```Elixir

def is_signature_valid?(certificate, signature, body) do
  Alexa.Records.certificate(tbsCertificate: tbs_certificate) = certificate
  certificate_from_amazon?(certificate)
  |> verify_signature(tbs_certificate, signature, body)
end

defp certificate_from_amazon?(certificate) do
    Alexa.Records.certificate(tbsCertificate: tbs_certificate) = certificate
    Alexa.Records.tbs_certificate(extensions: extensions) = tbs_certificate
    Enum.reduce(extensions, false, fn(extension, acc) ->
      acc || case extension do
        {_, {2, 5, 29, 17}, _, [dNSName: 'echo-api.amazon.com']} ->
          true
        _ ->
          false
      end
    end)
  end
```

If the certificate is from amazon, we then go on to verifying the signature
by extracting the public key, verifying the `signature` header by comparing it
with the post body.

```Elixir
defp verify_signature(true, tbs_certificate, signature, body) do
  Alexa.Records.tbs_certificate(subjectPublicKeyInfo: public_key_info) = tbs_certificate
  Alexa.Records.subject_public_key_info(subjectPublicKey: key) = public_key_info
  {:ok, signature} = Base.decode64(signature)

  case :public_key.verify(body, :sha, signature, key) do
    true ->
      {:ok}
    false ->
      {:error, :invalid_signature}
  end
end

defp verify_signature(false, _, _, _) do
  {:error, :not_amazon}
end


```
### Verifying the App ID

Verifying the Application ID is trivial, you just need to make sure that the
identifier in the request body is the same as your application. There isn't
much interesting here.

```elixir
defmodule Alexa.ValidateAppID do
  import Plug.Conn

  def init(opts) do
    Keyword.fetch!(opts, :app_id)
  end

  def call(conn, app_id) do
    case conn.body_params.session.application.applicationId do
      ^app_id ->
        conn
      _ ->
        conn
        |> resp(401, "Invalid App ID")
        |> halt()
    end
  end
end
```

### Verifying the timestamp

Verifying the timestamp is also trivial. We just parse out the request timestamp
using Timex, and check if it's within the last 10 minutes.

```elixir
defmodule Alexa.ValidateTimestamp do
  import Plug.Conn

  def init(opts) do
    opts
  end

  def call(conn, _) do
    timestamp = conn.body_params.request.timestamp
    {:ok, date} =  Timex.parse(timestamp, "{ISO:Extended}")
    date = date
    now = Timex.now

    if Timex.diff(date, now, :minutes) > 10 do
      resp(conn, 401, "expired request")
      |> halt()
    else
      conn
    end
  end
end
```

## Providing a "controller" API

I am building this on top of Phoenix, but I wanted specific entry points for
the Alexa requests instead of handling everything in a post action. I did this
by doing a few things. First, I created a simple phoenix controller that handles
the post action. Then I wrote a plug, where you pass in an module that handles
alexa requests. These are then brought together by a macro such that you can do
the following in your router:

```Elixir
  Alexa.skill "/alexa/kitchen", App.KitchenSkill, app_id: "amzn1.ask.skill.xxx", auth_handler: Alexa.AuthHandler
```

### Passing the handler module through.

This is fairly trivial, we just add the skill to `assigns`

```Elixir
defmodule Alexa.SkillPlug do
  import Plug.Conn

  def init(opts) do
    Keyword.fetch!(opts, :skill)
  end

  def call(conn, skill) do
    assign(conn, :skill, skill)
  end

end
```

### Handling user Authentication
I added an optional user authentication pass. This is specified using the `auth_handler:`
option above. This is a module that exposes an `authenticate_user` method and returns
either `{:ok, user}` or `{:error, response}` as demonstrated below. If the error
tuple is returned, the plug will halt the connection.

```Elixir
defmodule App.AlexaAuthHandler do
  def authenticate_user(access_token) do
    case  Guardian.decode_and_verify(access_token) do
      {:ok, claims} ->
        App.GuardianSerializer.from_token(claims["sub"])
      {:error, _reason} ->
        response = %Alexa.ResponseBody{}
        {:error, response}
    end
  end
end
```

### Handling request types

There are a few request types that Alexa can send.
* Launch Requests
* Handle Intent
* Session Ended Requests.

This work is done via the skill handler specified above. Here is my skill
behavior.

```Elixir
defmodule Alexa.Skill do
  defmacro __using__(_opts) do
    quote do
      import Alexa.API
      @behaviour Alexa.Skill

      def handle_intent(conn, name, _request) do
        {conn, nil}
      end

      def handle_launch(conn, _request) do
        {conn, nil}
      end

      def handle_session_end(conn, _request) do
        {conn, nil}
      end
      defoverridable [handle_intent: 3, handle_launch: 2, handle_session_end: 2]
    end
  end

  @callback handle_intent(Plug.Conn.T, String.T, Alexa.RequestBody) :: {Plug.Conn.T, Alexa.ResponseBody}
  @callback handle_launch(Plug.Conn.T, Alexa.RequestBody) :: {Plug.Conn.T, Alexa.ResponseBody}
  @callback handle_session_end(Plug.Conn.T, Alexa.RequestBody) :: {Plug.Conn.T, Alexa.ResponseBody}

end
```

`handle_intent` is the most interesting of these as it allows you to match on
the intent type in your skill schema.

Finally, the macro puts it all together:

```Elixir
defmacro skill(path, controller, options) do
  path_atom = String.to_atom(path)
  quote bind_quoted: [options: options], unquote: true do
    pipeline unquote(path_atom) do
      plug :accepts, ["json"]
      plug Alexa.ValidateAppID, app_id: Keyword.get(options, :app_id)
      plug Alexa.ValidateTimestamp
      plug Alexa.AuthenticateUser, auth_handler: Keyword.get(options, :auth_handler)
      plug Alexa.SkillPlug, skill: unquote(controller)
    end

    scope unquote(path) do
      pipe_through [unquote(path_atom)]
      post "/", Alexa.Controller, :index
    end
  end
end

```

First, we create a pipeline, we atomize the path to name the pipeline to avoid conflicts.
Then we configure all the plugs we created.

Then, we create a scope that passes through the generic Alexa.Controller, which
reads the skill and passes control over to it.

### Providing a response composition API

As in my [apns](/blog/apns_elixir/) response objects, I like composing them using
elixir pipes. When I set out to build an API for creating Alexa responses, I wanted
the same style. For these, I created an `Alexa.API` module that has chainable
modules. These are then automatically imported into the Alexa Controllers.

```Elixir

defmodule Alexa.API do
  def continue_session(response \\ %Alexa.ResponseBody{}) do
    Kernel.put_in(response.response.shouldEndSession, false)
  end

  def put_session_attribute(response \\ %Alexa.ResponseBody{}, key, value) do
    Map.put(response, :sessionAttributes, Map.put(response.sessionAttributes, key, value))
  end

  def say(response \\ %Alexa.ResponseBody{}, text) do
    Kernel.put_in(response.response.outputSpeech, %Alexa.OutputSpeech{text: text})
  end

  def say_ssml(response \\ %Alexa.ResponseBody{}, text) do
    Kernel.put_in(response.response.outputSpeech, %Alexa.OutputSpeech{type: "SSML", ssml: text})
  end

  def card(response \\ %Alexa.ResponseBody{}, type, title, content, text, image) do
    Kernel.put_in(response.response.card, %Alexa.Card{type: type, title: title, content: content, text: text, image: image})
  end

  def card(response \\ %Alexa.ResponseBody{}, card) do
    Kernel.put_in(response.response.card, card)
  end
end
```

This can then be used as follows:

```Elixir
def handle_intent(conn, "For", _request) do
  response = say("hello")
  |> continue_session()
  |> put_session_attribute("hello", "world")

  {conn, response}
end
```

And that's that. I hope to deploy some skills soon with this framework.

## What's missing?

Tests, so many tests. I hope to get to those soon.
