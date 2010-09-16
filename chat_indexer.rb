#!/usr/bin/env ruby
#=Xchat Fulltext indexer plugin
#Organize fulltext index from IRC messages upon "Groonga", and perform search.
#
#Author::       Mikiya Okuno
#Version::      1.0
#License::      GPLv2 or later
#Copyright::    Copyright (c) 2010, Mikiya Okuno. All rights reserved.

#--
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#++

include XChatRuby

require 'pathname'
require 'fileutils'
begin
  require 'groonga'
rescue LoadError
  require 'rubygems'
  require 'groonga'
end

module XChatIndexer
#
# Data access object
#
  class GrnDatabase
    def initialize
      @database = nil
    end
    attr_reader :database

    def reset_context(encoding)
      Groonga::Context.default_options = {:encoding => encoding}
      Groonga::Context.default = nil
    end

    def open(base_path, encoding)
      reset_context(encoding)
      path = File.join(base_path, "xchat_index.db")
      if File.exist?(path)
        @database = Groonga::Database.open(path)
      else
        FileUtils.mkdir_p(base_path)
        @database = Groonga::Database.create(:path => path)
        define_schema
      end
    end

    def close
      @database.close
      @database = nil
    end

    def closed?
      @database.nil? or @database.closed?
    end

    # Add an individual message to Groonga.
    def add_message(attributes)
      Groonga['Messages'].add(attributes)
    end

    # a simple method to organize a hash including a record
    def get_message_as_hash(r)
      {
        :id => r.id,
        :server => r.server,
        :channel => r.channel,
        :nick => r.nick,
        :message => r.message,
        :timestamp => r.timestamp,
        }
    end

    # Perform fulltext search
    def find_message(server ,channel, words, n)
      query = "server:#{server} + channel:#{channel} "\
          << words.collect {|w| "message:@#{w}"}.join(' + ')
      Groonga['Messages'].select do |record|
        record.match(query)
      end.sort([["_id", :descending]], :limit => n).collect do |r|
        get_message_as_hash(r)
      end.reverse
    end

    # Display messages before/after the certain message on the specific server/channel
    def show_n_messages(msg_id, n)
      the_record = Groonga['Messages'].select do |record|
        record.id == msg_id
      end.collect do |r|
        get_message_as_hash(r)
      end
      return nil if the_record.nil? or the_record.size == 0
      the_record = the_record[0]

      query = "server:#{the_record[:server]} + channel:#{the_record[:channel]}"
      messages = Groonga['Messages'].select do |record|
        record.match("#{query} + _id:<#{msg_id}")
      end.sort([["_id", :descending]], :limit => n/2).collect do |r|
        get_message_as_hash(r)
      end.reverse.push(the_record).concat(
        Groonga['Messages'].select do |record|
          record.match("#{query} + _id:>#{msg_id}")
        end.sort([["_id", :ascending]], :limit => n/2).collect do |r|
          get_message_as_hash(r)
        end
      )
    end

    # Define the schema to store messages
    def define_schema
      Groonga::Schema.define do |schema|
        schema.create_table("Topics",
                            :type => :patricia_trie,
                            :key_type => "ShortText") do |table|
        end

        schema.create_table("Messages",
                            :type => :array) do |table|
          table.short_text("server")
          table.short_text("channel")
          table.short_text("nick")
          table.reference("topic", "Topics")
          table.text("message")
#           table.boolean("highlighted")
          table.time("timestamp")
        end

        schema.create_table("Terms",
                            :type => :patricia_trie,
                            :key_type => "ShortText",
                            :default_tokenizer => "TokenMecab",
                            :key_normalize => true) do |table|
          table.index("Messages.message")
          table.index("Topics._key")
        end
      end
    end
  end
end

#
# The main plugin
#
class XChatIndexerPlugin < XChatRubyRBPlugin
  HELP_MESSAGE='
  /indexer
         help           ... Show this help.
         find {word}    ... Do fulltext search.
         show {msg_id}  ... Display individual lines around a certain msg_id.
         last           ... Display the last search result.
         lines [#]      ... Show/set lines to display results. Default is 20.
'

  # Populate instance variables and define hooks.
  def initialize
    @script_name = "xchat indexer 1.0"
    @n_lines = 20
    @last_result = nil
    @db = XChatIndexer::GrnDatabase.new
    path = File.join(get_info('xchatdir'), 'indexer_db')
    @db.open(path, 'utf-8')

    hook_print("Channel Message", XCHAT_PRI_LOWEST, method(:message_hook),
               "Channel Message.")
    hook_print("Channel Msg Hilight", XCHAT_PRI_LOWEST, method(:message_hook),
               "Channel Msg Hilight.")
    hook_print("Channel Action Hilight", XCHAT_PRI_LOWEST, method(:message_hook),
               "Channel Action Hilight.")

    ["MSG", "ME", "SAY", ""].each do |cmd|
      hook_command(cmd, XCHAT_PRI_LOWEST, method(:say_hook), cmd)
    end

    hook_command("INDEXER", XCHAT_PRI_NORM, method(:indexer_command),
                 "Usage: Indexer <cmd>, see /indexer help for more info")

    puts "#Script '#{@script_name}' loaded"
  end

  # A hook function called when a channel message arrives.
  def message_hook(words, data)
    highlight = data =~ /highlight/i ? true : false
    add_message(words[0], words[1], highlight)
    return XCHAT_EAT_PLUGIN
  end

  # A hook function called when "I" send a message.
  def say_hook(words, words_eol, data)
    add_message(get_info('nick'), words_eol[0])
    return XCHAT_EAT_PLUGIN
  end

  # Pack IRC related information with a message into hash and store it.
  def add_message(nick, msg, highlight=false)
    attributes = {
      :server => get_info('server'),
      :channel => get_info('channel'),
      :nick => nick,
      :topic => get_info('topic'),
      :message => msg,
#     :highlighted => highlight,
      :timestamp => Time.now
    }
    @db.add_message(attributes)
  end

  # Handle "/indexer" commands. A user interacts to this plugin thru this command.
  def indexer_command(words, words_eol, data)
    if words.length < 2
      display_help
    else
      case words[1].downcase
      when "help"
        display_help
      when "lines"
        unless words[2].nil?
          @n_lines = words[2].to_i
        end
        puts "indexer: current n_lines setting = #{@n_lines}."
      when "find"
        find_in_channel words_eol[2]
      when "show"
        show_n_messages words[2].to_i
      when "last"
        print_results
      when "test"
        do_test
      end
    end
    return XCHAT_EAT_NONE
  end

  def do_test
  end

  # Display a help to the current message box.
  def display_help
    puts HELP_MESSAGE
  end

  # Display search results.
  def print_results
    return if @last_result.nil?
    @last_result.each do |res|
      next unless msg_id = res[:id] # for safety
      msg_id = msg_id.to_s.ljust(6)
      timestamp = (res[:timestamp] ? res[:timestamp].strftime('%Y-%m-%d %H:%m') : 'NULL').ljust(16)
      nick = (res[:nick] || 'NULL').ljust(10)
      message = res[:message] || 'NULL'
      puts "#{msg_id} | #{timestamp} | #{nick}: #{message}"
    end
    print_result_summary
  end

  # Format period of time pretty
  def pretty_time(t)
    day = (t / (24 * 60 * 60)).to_i
    hour = (t % (24 * 60 * 60) / (60 * 60)).to_i
    min = (t % (60 * 60) / 60).to_i
    sec = sprintf('%.2f', (t % 60))
    case
    when t < 60
      "#{sec} sec"
    when t < 60 * 60
      "#{min} min #{sec} sec"
    when t < 60 * 60 * 24
      "#{hour} hour #{min} min #{sec} sec"
    else
      "#{day} day #{hour} hour #{min} min #{sec} sec"
    end
  end

  # print query statistics
  def print_result_summary
    size = @last_result.nil? ? 0 : @last_result.size
    res_desc = size == 0 ? 'Empty set' : "#{size} row#{size > 1 ? 's' : ''} in set"
    res_desc << " (#{pretty_time(Time.new - @start_time)})" if @start_time
    puts res_desc
    @start_time = nil
  end

  # Perform fulltext search and display results.
  def find_in_channel(words)
    @start_time = Time.new
    puts "Search results for '#{words}':"
    @last_result = @db.find_message(get_info('server'), get_info('channel'), words, @n_lines)
    print_results
  end

  # Display a certain message with messages before/after it.
  def show_n_messages(msg_id)
    @start_time = Time.new
    puts "Displaying #{@n_lines} messages around id #{msg_id}:"
    @last_result = @db.show_n_messages(msg_id, @n_lines)
    print_results
  end
end
