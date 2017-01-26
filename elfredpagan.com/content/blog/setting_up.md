+++
tags = ["ops"]
description = "What did I do to set up this site."
title = "Setting up"
date = "2017-01-25T17:35:04-06:00"
categories = ["development"]
draft = true
+++

I figured a good way of kicking off this site would be writing how it's set up.
I have it deployed on [linode](http://linode.com) using [Hugo](http://gohugo.io)
and the NGINX docker container. The idea being that when I'm experimenting, I
can easily deploy containers with whatever services I'm building and use NGINX
as a frontend.

# Remote login and user setup.

After creating my linode, the first thing I did was setup a sudo user and disabled
root login in ssh.

first things first:

```
root@ubuntu:~# adduser myuser
root@ubuntu:~# usermod -aG sudo myuser
```

At this point, I log out as root and log in as my new user. I then disabled root
login in the sshd config:

```
# /etc/ssh/sshd_config
...
# Authentication:
LoginGraceTime 120
PermitRootLogin no
StrictModes yes
...
```

And restarted sshd:

```
myuser@ubuntu:~$ sudo /etc/init.d/ssh restart
```

I then went on to install docker:
```
myuser@ubuntu:~$ sudo apt-get install dmsetup && dmsetup mknodes
myuser@ubuntu:~$ sudo curl -sSL https://get.docker.com/ | sh
```

I also added my user to the docker group:
```
myuser@ubuntu:~$ sudo usermod -aG docker elfredpagan
```

and Installed docker compose:
```
myuser@ubuntu:~$ sudo apt install docker-compose
```

At this point I have a working docker and docker-compose installation.
Now I installed Hugo.
```
myuser@ubuntu:~$ wget https://github.com/spf13/hugo/releases/download/v0.18.1/hugo_0.18.1-64bit.deb
myuser@ubuntu:~$ sudo dpkg -i hugo*.deb
```

And pulled my repository
```
myuser@ubuntu:~$ git clone $github_url:repository
myuser#ubuntu:~$ cd repository
```

My repository has a `site` folder that contains a Hugo site. Hugo builds your site in the `public`
folder, so I have a docker-compose.yml file that looks as follows.

```yaml
web:
  image: "nginx:alpine"
  ports:
    - "80:80"
    - "443:443"
  volumes:
    - "./site/public:/usr/share/nginx/html"
```

I then have a startup script that runs `docker-compose up` to start the http
service.

That's pretty much it for now, I have to setup a cron job to poll the github
repository and rebuild the site as needed. I also expect to export the nginx
configuration to a mapped volume as things get more complex.
