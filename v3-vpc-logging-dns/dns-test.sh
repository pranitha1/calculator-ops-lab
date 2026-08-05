#!/bin/bash
echo "127.0.0.1 app.calculator.internal" | tee -a /etc/hosts
echo "172.31.21.167 db.calculator.internal" | tee -a /etc/hosts
ping -c 1 app.calculator.internal
ping -c 1 db.calculator.internal
