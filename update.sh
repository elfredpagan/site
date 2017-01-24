#!/usr/bin/env bash
cd "$(dirname "$0")"
git pull
cd elfredpagan.com
hugo
