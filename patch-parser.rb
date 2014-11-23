#!/usr/bin/env ruby

require 'pp'
require 'nokogiri'
require 'mail'
require 'time'
require 'date'

# Dep3 parser
# use .parse! -> check .valid -> read with []
#
# Be very mindful of which functions from standard Hash are overriden here.
# This class adds compatibility mapping on top of certain Hash functions, if
# a function is not overriden it likely doesn't have the mapping so not all
# possibly key values outlined in the spec will work.
# Specifically this class always uses the first mentioned version of a field name
# in the spec as the key value for internal storage. For example Author > From.
# So, while you can use d['From'] just fine, internally it is really d['Author']
# that you get returned. Should you then try to use the From key on non-overriden
# functions like delete you'll not have deleted the key because it was called
# Author all along. To transparently map you can use .get_alias(key) which will
# always give you the correct key name.
class Dep3 < Hash
    NONE_STATE = 0 # nothing to see here
    HEADER_STATE = 1 # actively working on a header field, following fields may be folding
    FREEFORM_STATE = 2 # processing freeform content

    attr_reader :filepath
    attr_accessor :valid

    def initialize(filepath)
        @filepath = filepath
        @valid = false
        @aliases = {
            'Description' => 'Subject',
            'Author' => 'From',
            'Reviewed-by' => 'Acked-by',
            }
    end

    def get_alias(key)
        @aliases.each do |alias_key, alias_value|
            return alias_key if key == alias_value
        end
        return key
    end

    def [](key)
        super(get_alias(key))
    end

    def []=(key,value)
        super(get_alias(key), value)
    end

    def parse!()
        state = NONE_STATE
        current_header = nil

        data = {}

        File.readlines(@filepath).each do |line|
            begin
              break if line.strip == '---'
            rescue
              pp "This patch is weird"
              next
            end

            header_match = line.match(/^(\S+):(.*)/)
            if not header_match.nil?
                # 0 = full match
                # 1 = key match
                # 2 = value match
                key = header_match[1].lstrip
                value = header_match[2].lstrip
                if self[key].nil?
                    self[key] = value
                else # append
                    self[key] << "\n#{value}"
                end
                state = HEADER_STATE
                current_header = key
                next
            end

            fold_match = line.match(/^\s(.+)/)
            if not fold_match.nil? and state == HEADER_STATE
                # Folding value encountered -> append to header.
                # 0 full match
                # 1 value match
                value = fold_match[1].lstrip
                self[current_header] << "\n#{value}"
                next
            end

            if line == '\n' and state == FREEFORM_STATE
                state = NONE_STATE
                next
            end

            # The line is not a header, nor is it an exepected folding value or
            # ending freeform parsing.
            # In all cases we are now entering a freeform state. The only
            # way to leave free form is through \n\n or parsing end.
            # In freeform all lines are appended to __freeDescription verbatim.
            # Later if an actual description field was found it will be
            # appended to the Description field for outside consumption.
            # The dep3 spec explicitly requires a Description or Subject
            # field to be present, directly appending to the relevant field
            # in the hash therefore would make checking this unnecessarily
            # difficult.

            # drop \n to prevent newlines piling up, except when there is only
            # a newline, we want to preserve those.
            line.chomp! unless line.dup.chomp!.length == 0

            if self['__freeDescription'].nil?
                self['__freeDescription'] = line
            else
                self['__freeDescription'] << "\n#{line}"
            end

            state = FREEFORM_STATE
            current_header = nil
            next
        end

        # Check for required headers.
        return if self['Description'].nil?
        return if self['Origin'].nil? and self['Author'].nil?

        # Patch is legit dep3, append free form description lines to actual
        # description.
        self['Description'] << "\n#{self['__freeDescription']}"
        self.delete('__freeDescription')

        # Bonus: strip useless characters from all values
        self.each do |key, value|
            self[key].strip!
        end

        @valid = true
    end
end

if ARGV.empty?
  pp "Need atleast one argument"
  exit
end

EMAIL_BODY = 'Hi
              This is a automated email about some patch(es) that you might have touched recently.
              A automated check noticed that the following patches were not DEP 3\'d properly.
              As the last person who touched these patches, please add DEP 3 headers to these patches.
              '

emailDb = {}
emailDb.default = []

@page = Nokogiri::HTML(File.open('ubuntu-patch-status.html', 'r'))
tableElement = @page.at_css "tbody"

ARGV.each do |package|
    packageName = package.split(':')[-1].split('/')[-1].split('.')[0]
    if Dir.exists? packageName
      Dir.chdir(packageName) { `git checkout kubuntu_unstable && git pull` }
    else
      `git clone --branch kubuntu_unstable #{package}`
    end
    patches = Dir.glob("./#{packageName}/debian/patches/**/**")
    patches.each do |patch|
      # Filter out what's not a patch
      patches.delete(patch) if File.directory?(patch) or patch.split("/")[-1] == "series"
    end

    next if patches.empty?

    tableEntry = Nokogiri::XML::Node.new "tr", @page
    tableEntry.parent = tableElement

    # Package Name
    packageEntry = Nokogiri::XML::Node.new "td", @page
    packageEntry.content = packageName
    packageEntry['class'] = "pkg-#{package}"
    packageEntry['rowspan'] = "#{patches.count}"
    packageEntry.parent = tableEntry

    patches.each do |patch|
      if patch != patches.first
        tableEntry2 = Nokogiri::XML::Node.new "tr", @page
        tableEntry2.parent = tableEntry
      end

      ## Patch parsing
      patchName = patch.split("/")[-1]
      parser = Dep3.new(patch)
      parser.parse!()

      # Patch Name

      # Classify the patch
      if patchName =~ /upstream_.*/
        patchClass = "upstream"
      elsif patchName =~ /kubuntu_.*/
        patchClass = "kubuntu"
      else
        patchClass = "other"
      end

      patchEntry = Nokogiri::XML::Node.new "td", @page
      patchEntry['class'] = "patch-#{patchClass}"
      # TODO: Fix this shit later on.
      patchEntry.parent = patch == patches.first ? tableEntry : tableEntry2

      patchLink = Nokogiri::XML::Node.new "a", @page
      patchLink['href'] = 'http://anonscm.debian.org/cgit/pkg-kde/' + package.split(':')[-1] + '/tree/debian/patches/' + patchName + '?h=kubuntu_unstable'
      patchLink.parent = patchEntry
      patchLink.content = patchName

      # Dep 3 ?
      dep3Entry = Nokogiri::XML::Node.new "td", @page
      dep3Entry.content = parser.valid
      dep3Entry['class'] = "dep3-#{parser.valid}"
      dep3Entry.parent = patch == patches.first ? tableEntry : tableEntry2

      # Author
      authorEntry = Nokogiri::XML::Node.new "td", @page
      authorEntry.content = parser['Author'].nil? ? Dir.chdir(packageName) {`git log -1 debian/patches/#{patchName} | grep Author |  cut -d : -f2-`.chomp } : parser['Author']
      authorEntry.parent = patch == patches.first ? tableEntry : tableEntry2

      # Last-Update
      updateEntry = Nokogiri::XML::Node.new "td", @page
      date = parser['Last-Update'].nil? ? Dir.chdir(packageName) { Date.parse(`git log -1 debian/patches/#{patchName} | grep Date |  cut -d : -f2-`.chomp) } : parser['Last-Update']
      updateEntry.content = date
      updateEntry.parent = patch == patches.first ? tableEntry : tableEntry2
    end
end

File.open('patch.html', 'w'){ |f| f.write(@page.to_s) }

# pp "Sending out emails"

# emailDb.each do |key, array|
#   raw_address = Mail::Address.new(key)
#   mail = Mail.new do
#     from 'rohangarg@kubuntu.org'
#     to   raw_address.address
#     subject 'Missing Dep 3 headers'
#     body EMAIL_BODY + array.join('\n')
#   end
# 
#   mail.deliver!
# end
