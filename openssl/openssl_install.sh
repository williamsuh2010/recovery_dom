#!/bin/bash
set -x #echo on

unzstd openssl-1.1-1.1.1.w-1-x86_64.pkg.tar.zst
tar -xvf openssl-1.1-1.1.1.w-1-x86_64.pkg.tar

cp usr/lib/libcrypto.so.1.1 /usr/lib/libcrypto.so.1.1
cp usr/lib/libssl.so.1.1 /usr/lib/libssl.so.1.1