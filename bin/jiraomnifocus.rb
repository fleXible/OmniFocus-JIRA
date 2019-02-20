#!/usr/bin/env ruby

require 'bundler/setup'
Bundler.require(:default)

require 'cgi'
require 'rb-scpt'
require 'json'
require 'yaml'
require 'net/http'
require 'keychain'
require 'pathname'

def get_opts
	if File.file?(ENV['HOME']+'/.jofsync.yaml')
		config = YAML.load_file(ENV['HOME']+'/.jofsync.yaml')
	else config = YAML.load <<~EOS
		#YAML CONFIG EXAMPLE
		---
		jira:
		  hostname: 'http://please-configure-me-in-jofsync.yaml.atlassian.net'
		  keychain: false
		  auth_method: 'basic_auth'
		  username: ''
		  password: ''
		  filter:   'resolution = Unresolved and issue in watchedissues()'
		omnifocus:
		  context:  'Office'   # The default OF Context where new tasks are created.
		  project:  'Jira'     # The default OF Project where new tasks are created.
		  flag:     true       # Set this to 'true' if you want the new tasks to be flagged.
		  inbox:    false      # Set 'true' if you want tasks in the Inbox instead of in a specific project.
		  newproj:  false      # Set 'true' to add each JIRA ticket to OF as a Project instead of a Task.
		  folder:   'Jira'     # Sets the OF folder where new Projects are created (only applies if 'newproj' is 'true').
		EOS
	end

	Optimist::options do
		version "jofsync 1.1.0"
		banner <<~EOS
			Jira OmniFocus Sync Tool
			
			Usage:
			    jofsync [options]
			
			KNOWN ISSUES:
			    * With long names you must use an equal sign ( i.e. --hostname=test-target-1 )
		EOS
		opt :use_keychain,'Use Keychain for Jira',:type => :boolean,:short => 'k', :required => false,   :default => config["jira"]["keychain"]
		opt :auth_method, 'Auth-Method',        :type => :string,   :short => 'a', :required => false,   :default => config["jira"]["auth_method"]
		opt :username,  'Jira Username',        :type => :string,   :short => 'u', :required => false,   :default => config["jira"]["username"]
		opt :password,  'Jira Password',        :type => :string,   :short => 'p', :required => false,   :default => config["jira"]["password"]
		opt :hostname,  'Jira Server Hostname', :type => :string,   :short => 'h', :required => false,   :default => config["jira"]["hostname"]
		opt :filter,    'JQL Filter',           :type => :string,   :short => 'j', :required => false,   :default => config["jira"]["filter"]
		opt :context,   'OF Default Context',   :type => :string,   :short => 'c', :required => false,   :default => config["omnifocus"]["context"]
		opt :project,   'OF Default Project',   :type => :string,   :short => 'r', :required => false,   :default => config["omnifocus"]["project"]
		opt :flag,      'Flag tasks in OF',     :type => :boolean,  :short => 'f', :required => false,   :default => config["omnifocus"]["flag"]
		opt :folder,    'OF Default Folder',    :type => :string,   :short => 'o', :required => false,   :default => config["omnifocus"]["folder"]
		opt :inbox,     'Create inbox tasks',   :type => :boolean,  :short => 'i', :required => false,   :default => config["omnifocus"]["inbox"]
		opt :newproj,   'Create as projects',   :type => :boolean,  :short => 'n', :required => false,   :default => config["omnifocus"]["newproj"]
		opt :quiet,     'Disable output',       :type => :boolean,  :short => 'q',                       :default => true
	end
end

# This method gets all issues that are assigned to your USERNAME and whos status isn't Closed or Resolved.  It returns a Hash where the key is the Jira Ticket Key and the value is the Jira Ticket Summary.
def get_issues
	puts "JOFSYNC.get_issues: starting method..." if $DEBUG
	jira_issues = Hash.new

	# This is the REST URL that will be hit.  Change the jql query if you want to adjust the query used here
	uri = URI($opts[:hostname] + '/rest/api/2/search?jql=' + URI::encode($opts[:filter]))

	puts "JOFSYNC.get_issues: about to hit URL: " + uri.to_s if $DEBUG
	if $opts[:use_keychain]
		puts "JOFSYNC.get_issues: using Keychain for auth" if $DEBUG
		keychain_uri = URI($opts[:hostname])
		host = keychain_uri.host
		begin
			puts "JOFSYNC.get_issues: looking for first Keychain entry for host: " + host if $DEBUG
			keychain_item = Keychain.internet_passwords.where(:server => host).first
			$opts[:username] = keychain_item.account
			$opts[:password] = keychain_item.password
			puts "JOFSYNC.get_issues: username and password loaded from Keychain" if $DEBUG
		rescue Keychain::Error
			error_message = "Password not found in keychain; add it using 'security add-internet-password -a <username> -s #{host} -w <password>'"
			raise StandardError, error_message
		end
	end

	puts "JOFSYNC.get_issues: abount to connect...." if $DEBUG
	if $opts[:auth_method] == 'cookie'
		auth_uri = URI($opts[:hostname] + '/rest/auth/1/session')
		Net::HTTP.start(auth_uri.hostname, auth_uri.port, :use_ssl => auth_uri.scheme == 'https') do |http|
			request = Net::HTTP::Post.new(auth_uri, initheader = {'Content-Type' =>'application/json'})
			request.body = '{ "username": "' + $opts[:username] + '", "password": "' + $opts[:password] + '" }'
			response = http.request(request)

			if response.code =~ /20[0-9]{1}/
				puts 'Connected successfully to ' + uri.hostname + ' using Cookie-Auth'
				$session = JSON.parse(response.body)
			else
				raise StandardError, 'Unsuccessful Cookie-Auth: HTTP response code ' + response.code + ' from ' + uri.hostname
			end
		end
	end

	Net::HTTP.start(uri.hostname, uri.port, :use_ssl => uri.scheme == 'https') do |http|
		request = Net::HTTP::Get.new(uri)
		if $session['session']
			cookie = CGI::Cookie.new($session['session']['name'], $session['session']['value'])
			request['Cookie'] = cookie.to_s
		else
			request.basic_auth $opts[:username], $opts[:password]
		end
		response = http.request request
		# If the response was good, then grab the data
		puts "JOFSYNC.get_issues: response code: " + response.code if $DEBUG
		puts "JOFSYNC.get_issues: response body: " + response.body if $DEBUG
		if response.code =~ /20[0-9]{1}/
			puts "Connected successfully to " + uri.hostname
			data = JSON.parse(response.body)
			puts "JOFSYNC.get_issues: response parsed successfully!" if $DEBUG
			data["issues"].each do |item|
				jira_id = item["key"]
				puts "JOFSYNC.get_issues: adding JIRA item: " + jira_id + " to the jira_issues array" if $DEBUG
				jira_issues[jira_id] = item
			end
		else
			# Use terminal-notifier to notify the user of the bad response--useful when running this script from a LaunchAgent
			notify_message = "Response code: " + response.code
			TerminalNotifier.notify(notify_message, :title => "JIRA OmniFocus Sync", :subtitle => uri.hostname, :sound => 'default')
			raise StandardError, "Unsuccessful HTTP response code " + response.code + " from " + uri.hostname
		end
	end
	puts "JOFSYNC.get_issues: method_complete, returning jira_issues." if $DEBUG
	return jira_issues
end

# This method adds a new Task to OmniFocus based on the new_task_properties passed in
def add_task(omnifocus_document, new_task_properties)
	# If there is a passed in OF project name, get the actual project object
	puts "JOFSYNC.add_task: starting method..." if $DEBUG

	if new_task_properties['project']
		proj_name = new_task_properties["project"]
		puts "JOFSYNC.add_task: new task specified a project name of: " + proj_name + " so going to load that up" if $DEBUG
		proj = omnifocus_document.flattened_tasks[proj_name]
		puts "JOFSYNC.add_task: project loaded successfully" if $DEBUG
	end

	# Check to see if there's already an OF Task with that name
	# If there is, just stop.
	name   = new_task_properties["name"]
	puts "JOFSYNC.add_task: going to check for existing tasks with the same name: " + name if $DEBUG
	
	if $opts[:inbox]
		# Search your entire OF document, instead of a specific project.
		puts "JOFSYNC.add_task: inbox flag set, so need to search the entire OmniFocus document" if $DEBUG
		exists = omnifocus_document.flattened_tasks.get.find { |t| t.name.get.force_encoding("UTF-8") == name }
		puts "JOFSYNC.add_task: task exists = " + exists.to_s if $DEBUG
	elsif $opts[:newproj]
		# Search your entire OF document, instead of a specific project.
		puts "JOFSYNC.add_task: new project flag set, so need to search the entire OmniFocus document" if $DEBUG
		exists = omnifocus_document.flattened_tasks.get.find { |t| t.name.get.force_encoding("UTF-8") == name }
		puts "JOFSYNC.add_task: task exists = " + exists.to_s if $DEBUG
	else
		# If you are keeping all your JIRA tasks in a single Project, we only need to search that Project
		puts "JOFSYNC.add_task: searching only project: " + proj.name.get if $DEBUG
		exists = proj.tasks.get.find { |t| t.name.get.force_encoding("UTF-8") == name }
		puts "JOFSYNC.add_task: task exists = " + exists.to_s if $DEBUG
	end

	return false if exists

	# If there is a passed in OF context name, get the actual context object
	if new_task_properties['context']
		ctx_name = new_task_properties["context"]
		puts "JOFSYNC.add_task: new task specified a context of: " + ctx_name + " so going to load that up" if $DEBUG
		ctx = omnifocus_document.flattened_contexts[ctx_name]
		puts "JOFSYNC.add_task: context loaded successfully" if $DEBUG
	end

	# Do some task property filtering.  I don't know what this is for, but found it in several other scripts that didn't work...
	tprops = new_task_properties.inject({}) do |h, (k, v)|
		h[:"#{k}"] = v
		h
	end

	# Remove the project property from the new Task properties, as it won't be used like that.
	tprops.delete(:project)
	# Update the context property to be the actual context object not the context name
	tprops[:context] = ctx if new_task_properties['context']

	puts "JOFSYNC.add_task: task props - deleted project and set context" if $DEBUG

	# Create the task in the appropriate place as set in the config file
	if $opts[:inbox]
		# Create the tasks in your Inbox instead of a specific Project
		puts "JOFSYNC.add_task: adding Task to Inbox" if $DEBUG
		new_task = omnifocus_document.make(:new => :inbox_task, :with_properties => tprops)
		puts "Created inbox task: " + tprops[:name]
	elsif $opts[:newproj]
		# Create the task as a new project in a folder
		puts "JOFSYNC.add_task: adding Task as a new Project" if $DEBUG
		of_folder = omnifocus_document.folders[$opts[:folder]]
		new_task = of_folder.make(:new => :project, :with_properties => tprops)
		puts "Created project in " + $opts[:folder] + " folder: " + tprops[:name]
	else
		# Make a new Task in the Project
		puts "JOFSYNC.add_task: adding Task to project: " + proj_name if $DEBUG
		proj.make(:new => :task, :with_properties => tprops)
		puts "Created task [" + tprops[:name] + "] in project " + proj_name
	end 
	puts "JOFSYNC.add_task: completed method." if $DEBUG
	true
end

# This method is responsible for getting your assigned Jira Tickets and adding them to OmniFocus as Tasks
def add_jira_tickets_to_omnifocus (omnifocus_document)
	# Get the open Jira issues assigned to you
	puts "JOFSYNC.add_jira_tickets_to_omnifocus: starting method... and about to get_issues" if $DEBUG
	results = get_issues
	puts "JOFSYNC.get_issues: early exit!" if $DEBUG
	exit
	if results.nil?
		puts "No results from Jira"
		exit
	end

	puts "JOFSYNC.add_jira_tickets_to_omnifocus: looping through issues found." if $DEBUG
	# Iterate through resulting issues.
	results.each do |jira_id, ticket|
		puts "JOFSYNC.add_jira_tickets_to_omnifocus: looking at jira_id: " + jira_id if $DEBUG
		# Create the task name by adding the ticket summary to the jira ticket key
		task_name = "#{jira_id}: #{ticket["fields"]["summary"]}"
		puts "JOFSYNC.add_jira_tickets_to_omnifocus: created task_name: " + task_name if $DEBUG
		# Create the task notes with the Jira Ticket URL
		task_notes = "#{$opts[:hostname]}/browse/#{jira_id}\n\n#{ticket["fields"]["description"]}"

		# Build properties for the Task
		@props = {}
		@props['name'] = task_name
		@props['project'] = $opts[:project]
		@props['context'] = $opts[:context]
		@props['note'] = task_notes
		@props['flagged'] = $opts[:flag]
		unless ticket["fields"]["duedate"].nil?
			@props["due_date"] = Date.parse(ticket["fields"]["duedate"])
		end
		puts "JOFSYNC.add_jira_tickets_to_omnifocus: built properties, about to add Task to OmniFocus" if $DEBUG
		add_task(omnifocus_document, @props)
		puts "JOFSYNC.add_jira_tickets_to_omnifocus: task added to OmniFocus." if $DEBUG
		end
	puts "JOFSYNC.add_jira_tickets_to_omnifocus: method complete" if $DEBUG
end

def mark_resolved_jira_tickets_as_complete_in_omnifocus(omnifocus_document)
	# get tasks from the project
	puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: starting method" if $DEBUG
	omnifocus_document.flattened_tasks.get.find.each do |task|
		puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: About to iterate through all tasks in OmniFocus document" if $DEBUG
		puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: working on task: " + task.name.get if $DEBUG
		if !task.completed.get && task.note.get.match($opts[:hostname])
			puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: task is NOT already marked complete, so let's check the status of the JIRA ticket." if $DEBUG
			# try to parse out jira id
			full_url= task.note.get.lines.first.chomp
			puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: got full_url: " + full_url if $DEBUG
			jira_id=full_url.sub($opts[:hostname]+"/browse/","")
			puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: got jira_id: " + jira_id if $DEBUG
			# check status of the jira
			uri = URI($opts[:hostname] + '/rest/api/2/issue/' + jira_id)
			puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: about to hit: " + uri.to_s if $DEBUG
			Net::HTTP.start(uri.hostname, uri.port, :use_ssl => uri.scheme == 'https') do |http|
				request = Net::HTTP::Get.new(uri)
				if $session['session']
					cookie = CGI::Cookie.new($session['session']['name'], $session['session']['value'])
					request['Cookie'] = cookie.to_s
				else
					request.basic_auth $opts[:username], $opts[:password]
				end
				response = http.request request
				puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: response code: " + response.code if $DEBUG
				puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: response body: " + response.body if $DEBUG
				if response.code =~ /20[0-9]{1}/
					data = JSON.parse(response.body)
					# Check to see if the Jira ticket has been resolved, if so mark it as complete.
					resolution = data["fields"]["resolution"]
					puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: resolution: " + resolution.to_s if $DEBUG
					if resolution != nil
						# if resolved, mark it as complete in OmniFocus
						puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: resolution was non-nil, so marking this Task as completed. " if $DEBUG
						unless task.completed.get
							task.completed.set(true)
							puts "Marked task completed " + jira_id
							next
						end
					else
						# Moving the assignment check block into the else block here...  The upside is that if you resolve a ticket and assign it back
						# to the creator, you get the Completed checked task in OF which makes you feel good, instead of the current behavior where the task is deleted and vanishes from OF.
						# Check to see if the Jira ticket has been unassigned or assigned to someone else, if so delete it.
						# It will be re-created if it is assigned back to you.
						puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: Checking to see if the task was assigned to someone else. " if $DEBUG
						if ! data["fields"]["assignee"]
							puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: There is no assignee, so deleting. " if $DEBUG
							omnifocus_document.delete task
						else
							assignee = data["fields"]["assignee"]["name"].downcase
							puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: curent assignee is: " + assignee if $DEBUG
							if assignee != $opts[:username].downcase
								puts "JOFSYNC.mark_resolved_jira_tickets_as_complete_in_omnifocus: That doesn't match your username of \"" + $opts[:username].downcase + "\" so deleting the task from OmniFocus" if $DEBUG
								omnifocus_document.delete task
							end
						end
					end
				else
					raise StandardError, "Unsuccessful response code " + response.code + " for issue " + issue
				end
			end
		end
	end
end

def app_is_running(app_name)
	`ps aux` =~ /#{app_name}/ ? true : false
end

def get_omnifocus_document
	Appscript.app.by_name("OmniFocus").default_document
end

def check_options
	if $opts[:hostname] == 'http://please-configure-me-in-jofsync.yaml.atlassian.net'
		raise StandardError, "The hostname is not set. Did you create ~/.jofsync.yaml?"
	end
end

def main
	puts "JOFSYNC.main: Running..." if $DEBUG
	if app_is_running("OmniFocus")
		puts "JOFSYNC.main: OmniFocus is running so let's go!" if $DEBUG
		$opts = get_opts
		$session = ''
		check_options
		puts "JOFSYNC.main: Options have been checked, moving on...." if $DEBUG
		omnifocus_document = get_omnifocus_document
		puts "JOFSYNC.main: Got OmniFocus document to work on, about to add JIRA tickets to OmniFocus" if $DEBUG
		add_jira_tickets_to_omnifocus(omnifocus_document)
		puts "JOFSYNC.main: Done adding JIRA tickets to OmniFocus, about to mark resolved JIRA tickets as complete in OmniFocus." if $DEBUG
		mark_resolved_jira_tickets_as_complete_in_omnifocus(omnifocus_document)
		puts "JOFSYNC.main: Done!" if $DEBUG
	end
end

main
