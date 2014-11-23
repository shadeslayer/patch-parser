#!/usr/bin/env ruby

frameworks = `ssh git.debian.org ls /git/pkg-kde/frameworks`.split()
plasma = `ssh git.debian.org ls /git/pkg-kde/plasma`.split()

repos = []

frameworks.each do | repo |
    repos << 'debian:frameworks/' + repo
end

plasma.each do | repo |
    repos << 'debian:plasma/' + repo
end

puts `ruby patch-parser.rb #{repos.join(' ')}`