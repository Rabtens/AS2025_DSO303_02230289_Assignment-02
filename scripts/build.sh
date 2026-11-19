#!/usr/bin/env bash
# Builds build/lambda/ (code + pg8000) which Terraform zips. Run from repo root.
set -euo pipefail
rm -rf build/lambda && mkdir -p build/lambda
pip install --quiet --no-cache-dir pg8000==1.31.2 -t build/lambda
cp backend/*.py build/lambda/
echo "built build/lambda"
