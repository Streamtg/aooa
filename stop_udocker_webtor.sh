name: Go Check

on:
  push:
    branches: [ main, master ]
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.22'
      - name: Download dependencies
        run: go mod download
      - name: Build
        run: go build -o qooq-cinema-bot .
