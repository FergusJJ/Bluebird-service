#!/bin/bash

echo "Loading .env"
export $(cat .env | xargs)

echo "Building service"
swift run BluebirdService --apikey "$1"
