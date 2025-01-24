#!/usr/bin/env ruby
# -*- coding: utf-8 -*-

Gem::Specification.new do |s|
  s.name = "pry-remote-reloaded"

  s.version = "1.1.0"

  s.summary     = "Connect to Pry remotely"
  s.description = "Connect to Pry remotely using DRb"
  s.homepage    = "https://github.com/Jack12816/pry-remote-reloaded"

  s.email   = "mon.ouie@gmail.com"
  s.authors = ["Mon ouie"]

  s.files |= Dir["lib/**/*.rb"]
  s.files |= Dir["*.md"]
  s.files << "LICENSE"

  s.require_paths = ["lib"]

  s.add_dependency "slop", "~> 3.0"
  s.add_dependency "pry", ">= 0.14"
  s.add_dependency "drb", "~> 2.2"

  s.executables = ["pry-remote"]
end
