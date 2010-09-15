#!/usr/bin/env ruby
#=Xchat automatic greeting plugin
#Say greetings to known nicknames.
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

class GreetsConfig
  def initialize(plugin, filename)
    eval File.read(filename)
  end

  def greets_delay(d=5)
    @delay = d.to_i
  end

  def cooling_off_period(t=3600)
    cooling_off_period = t.to_i
  end

  def greet_word(w=nil)
    @greet_word=w
  end
end

class AutoGreets < XChatRubyRBPlugin
  HELP_MESSAGE = '
  /greet
        help           ... Show this help.
        all            ... Say greetings to all known nicks.
        status         ... Show status per nick.
        list           ... List all nicks to say greetings.
        config         ... Display current config.
  '

  def initialize
    @script_name = "automatic greeting 1.0"

    @greet_word = "hi"
    @wb_word = "welcome back"
    @delay = 5
    @wb_period = 60 * 60
    @cooling_off_period = 60 * 60 * 8
    @greet_channel_list = []

    config_file = File.join(get_info('xchatdir'), 'greet.conf')
    if File.exists?(config_file)
      eval File.read(config_file)
    else
      puts "#{@script_name} was failed to load."
      return
    end

    nick_file = File.join(get_info('xchatdir'), 'known_nicks')
    if File.exists?(nick_file)
      @known_nicks = File.read(nick_file).split("\n").sort.uniq
      @known_nicks = @known_nicks.map {|x| x.gsub(/#.*$/, '').strip}
      @known_nicks.delete_if { |x| x =~/^$/ }
    else
      puts "#{@script_name} was failed to load."
      return
    end
    @status = init_status # key is nick, and contains a hash represents a status

    hook_print("Channel Message", XCHAT_PRI_NORM, method(:message_hook),
               "Channel Message.")
    hook_print("Channel Msg Hilight", XCHAT_PRI_NORM, method(:message_hook),
               "Channel Msg Hilight.")
    hook_print("Channel Action Hilight", XCHAT_PRI_NORM, method(:message_hook),
               "Channel Action Hilight.")

    hook_command("GREET", XCHAT_PRI_NORM, method(:handle_command),
                 "Usage: Greet <cmd>, see /greet help for more info")

    hook_print("Join", XCHAT_PRI_NORM, method(:join_hook), "Join.")
    hook_print("Part", XCHAT_PRI_NORM, method(:part_hook), "Part.")
    hook_print("Change Nick", XCHAT_PRI_NORM, method(:nick_change_hook), "Change Nick.")

    puts "#Script '#{@script_name}' loaded"
  end

  [:greet_word, :wb_word, :delay, :wb_period, :cooling_off_period].each do |m|
    define_method(m) do |val|
      sym = m.to_s.gsub(/^/, '@').to_sym
      instance_variable_set(sym, val)
    end
  end

  def add_greet_channel_list(ch)
    @greet_channel_list.push(ch)
  end

  def init_status
    status = {}
    @known_nicks.each do |nick|
      status[nick] = {
          :last_mention_time => nil,
          :last_mention_word => nil,
          :joined_time => nil,
          :left_time => nil,
          :last_greet => nil,
        }
    end
    status
  end

  def away?
    return ((not get_info('away').nil?) or\
            (get_info('nick') =~ /awa?y$|out$|afk$|bb[sl]$|lunch$/))
  end

  def say(words)
    command("SAY #{words}")
  end

  def normalize_nick(nick)
    nick.gsub(/\|.*$/, '').gsub(/\_.*$/, '').downcase
  end

  def say_hook(words, words_eol, data)
    add_message(get_info('nick'), words_eol[0])
    return XCHAT_EAT_NONE
  end

  def greet_all
    avail = get_users().find_all {|x| @known_nicks.include?(x.downcase) }
    avail << "all"
    say "#{@greet_word} #{avail.join(', ')}"
  end

  def handle_command(words, words_eol, data)
    if words.size < 2
      display_help
    else
      case words[1].downcase
      when "help"
        display_help
      when ""
        display_help
      when "all"
        greet_all
      when "status"
        print_status
      when "list"
        list_nicks
      when "config"
        show_config
      when "test"
        do_test
      end
    end
    return XCHAT_EAT_NONE
  end

  def do_test
    ctx = XChatRuby::XChatRubyEnvironment.find_context(nil, "#support_jp-spam")
    hash = {
      :words => "this is a test",
      :ctx => ctx,
      }
    hook_timer(@delay * 1000, method(:say_with_context), hash)
  end

  def display_help
    puts HELP_MESSAGE
  end

  def get_users
    ret = []
    users = XChatRuby::XChatRubyList.new("users")
    while users.next do
      ret.push(users.str('nick'))
    end
    ret.sort
  end

  def get_channels
    ret = []
    users = XChatRuby::XChatRubyList.new("channels")
    while users.next do
      ret.push(users.str('channel'))
    end
    ret.sort
  end

  def status_nick(nick)
    last_greet = (@status[nick].nil? or @status[nick][:last_greet].nil?) ?\
        '--' : @status[nick][:last_greet]
    puts "#{nick.ljust(16)}: #{last_greet}"
  end

  def print_status
    get_users().find_all{|x| @known_nicks.include?(x)}.sort.each do |u|
      status_nick(normalize_nick(u))
    end
  end

  def list_nicks
    @known_nicks.each do |nick|
      puts "#{nick.ljust(16)} | #{@status[nick][:last_mention_word] || 'nil'}"
    end
  end

  def show_config
    [:greet_word, :wb_word, :delay, :wb_period, :cooling_off_period].each do |v|
      sym = v.to_s.gsub(/^/, '@').to_sym
      val = instance_variable_get(sym)
      puts "#{v.to_s.ljust(20)}: #{val}"
    end
    puts "#{'greet_channel_list'.ljust(20)}: #{@greet_channel_list.join(', ')}"
  end

  def timed_print(words)
    ctx = XChatRuby::XChatRubyEnvironment.get_context()
    hash = {
        :words => words,
        :ctx => ctx,
      }
    hook_timer(@delay * 1000, method(:say_with_context), hash)
  end

  def say_with_context(hash)
    ctx = hash[:ctx]
    XChatRuby::XChatRubyEnvironment.set_context(ctx) unless ctx.nil?
    say(hash[:words])
  end

  def say_greetings(who)
    timed_print "#{@greet_word} #{who}"
  end

  def say_wb(who)
    timed_print "#{@wb_word} #{who}"
  end

  def say_greetings_or_wb(who, channel)
    return if @status[who].nil?

    period = @status[who][:last_greet].nil? ? @cooling_off_period + 1 : Time.new - @status[who][:last_greet]
    return if period < @wb_period

    if period < @cooling_off_period
      say_wb(who)
    else
      say_greetings(who)
    end
    @status[who][:last_greet] = Time.new
  end

  def join_hook(words, data)
    return XCHAT_EAT_NONE if away?
    channel = words[1].gsub(/^#/, '')
    unless @greet_channel_list.include? channel
      return XCHAT_EAT_NONE
    end
    say_greetings_or_wb(normalize_nick(words[0]), channel)
    return XCHAT_EAT_NONE
  end

  def nick_change_hook(words, data)
    return XCHAT_EAT_NONE if away?
    unless @greet_channel_list.include? words[1]
      return XCHAT_EAT_NONE
    end
    away_re = /[\|\_](afk|away|awy|zzz|bbl|brb|out)/i
    if words[0] =~ away_re and not words[1] =~ away_re
      say_greetings_or_wb(normalize_nick(words[1]), nil)
    end
    return XCHAT_EAT_NONE
  end

  def part_hook(words, data)
    words.each {|w| puts w}
  end

  def message_hook(words, data)
    channel = get_info('channel').gsub(/^#/, '')
    me = normalize_nick(get_info('nick'))
    who = normalize_nick(words[0])

    if words[1] =~ /#{me}/i
      @status[who] = {} if @status[who].nil?
      @status[who][:last_mention_time] = Time.new
      @status[who][:last_mention_word] = words[1]
    end
  end
end
