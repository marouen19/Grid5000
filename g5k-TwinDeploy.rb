require 'rubygems'
require 'restfully'       # gem install restfully
require 'net/ssh/gateway' # gem install net-ssh-gateway
require 'json'
require 'pp'
require 'yaml'

config       = YAML.load_file(File.expand_path("~/.restclient"))['grid5000']
public_key   = Dir[File.expand_path("/root/.ssh/*.pub")][0] 
fail "No public key available in /root/.ssh !" unless public_key
private_key  = File.expand_path("/root/.ssh/#{File.basename(public_key, ".pub")}")
fail "No private key corresponding to the public key available in ~/.ssh !" unless File.exist?(private_key)
logger       = Logger.new(STDERR)
logger.level = Logger::INFO
logger.info "Using the SSH public key located at: #{public_key.inspect}"
gateway      = Net::SSH::Gateway.new('access.lille.grid5000.fr', config['username'])

jobs         = []
deployments  = []

# Procedure called when exiting on error
extinction   = Proc.new{
  puts "Received extinction request, killing all jobs and deployments..."
  jobs.each{|job| job.delete}
  deployments.each{|deployment| deployment.delete}
}
#END extinction

# Trap signals and call the extinction procedure
%w{INT TERM}.each do |signal|
  Signal.trap( signal ) do
    extinction.call
    exit(1)
  end
end
#END trap

#main class
begin
n=0
m=0
n_message='empty';
n_message='empty';
temp=Hash.new
results_n= Hash.new
results_m=Hash.new
  Restfully::Session.new(:base_uri => config['url']+'/sid/grid5000', :logger => logger, :username => config['username'], :password => config['password']) do |root, session|

#Job Creation
    root.sites.each do |site|
	    next if %w{}.include?(site['uid']) # to limit the experiment's range

      free_nodes = site.status.inject(0) {|memo, node_status| memo+=((node_status['system_state'] == 'free' && node_status['hardware_state'] == 'alive') ? 1 : 0)}
      if free_nodes > 1
	needed_nodes= free_nodes/2
        #needed_nodes= "BEST"
	jobs << site.jobs.submit(:resources => "nodes=#{needed_nodes},walltime=00:60:00", :command => "sleep 1800", :types => ["deploy"], :name => "Grid Large Scale experiment") rescue nil
      else
        session.logger.info "Skipped #{site['uid']}. Not enough free nodes."
      end
    end
 #END Job creation

#Did we end up with no jobs?
    jobs.compact!
    if jobs.empty?
      logger.warn "No jobs, exiting..."
      extinction.call
      exit(0)
    end
#END job inspection

#start time out loop
    begin
      Timeout.timeout(60*15) do
        until jobs.all?{|job| job['state'] == 'running'} do
          session.logger.info "
	  Some jobs are not running. Waiting 10 seconds before checking again...
	  "
          sleep 10
          jobs.each{|job| job.reload}
        end
      end
    rescue Timeout::Error => e
      session.logger.warn "
      One of the jobs is still not running: #{jobs.inspect}. Will be deleted...
      "
    end
#END time out loop

#Deploy image if job running
    jobs.each do |job|
      if job['state'] != 'running'
        job.delete
      else
	       deployments << job.parent.deployments.submit(:environment => "lenny-x64-base", :nodes => job['assigned_nodes'], :key => File.read(public_key)) rescue nil
		k=job['assigned_nodes'].length
		m=m+k
	puts "ASSIGNED NODES:
	#{job['assigned_nodes'].pretty_inspect}
	
	#{k} new nodes are booked for the deployments...Total #{m}...

	"
      end
    end
#END deployment

#Did we end up with no deployments? 
 deployments.compact!
    if deployments.empty?
      logger.warn "No deployments, exiting..."
      extinction.call
      exit(0)
      end
#END deployment inspection


#begin timeout loop
    begin
      Timeout.timeout(60*15) do # wait at most 15mins
        until deployments.all?{|deployment| deployment['status'] == 'terminated'} do
          logger.info "
	  Some deployments are not terminated. Waiting 30 seconds before checking again...
	  "
          sleep 30
          deployments.each{|deployment| deployment.reload
      if deployment['status']=='terminated'
	      deployment['result'].each_key{|key| results_m.store(key, deployment['result']["#{key}"]['state'])}
	      puts "
	      
	      #{Time.new.strftime("%H:%M:%S")} Deployment on #{deployment['site_uid'] }'s #{deployment["nodes"].length} assigned nodes is terminated!!!!
	      "
	      
         
      else 
	      puts "Waiting for the deployment on #{deployment['site_uid'] }'s #{deployment["nodes"].length} assigned nodes to be terminated..."
      
      end
	}
	end
      end
    rescue Timeout::Error => e
      session.logger.warn "
      One of the deployments is still not terminated: it Will be deleted...
      "
    end
#END timeout loop

#Delete first deployments
    m_message="FIRST DEPLOYMENT: ############ #{results_m.size} nodes deployed over #{m} initail deployment#########";
    deployments.each do |deployment|
	  #  puts "#{results_m.pretty_inspect}"
	
	    puts "
	    #{m_message}
	    "
        deployment.delete
	end
#END delete first deployments
puts "
	Sleeping for 2 minutes
	
"
 sleep 120
 
#start time out loop
    begin
      Timeout.timeout(60*15) do
        until jobs.all?{|job| job['state'] == 'running'} do
          session.logger.info "
	  Some jobs are not running. Waiting 10 seconds before checking again...
	  "
          sleep 10
          jobs.each{|job| job.reload}
        end
      end
    rescue Timeout::Error => e
      session.logger.warn "
      One of the jobs is still not running: #{jobs.inspect}. Will be deleted...
      "
    end
#END time out loop

#Deploy image if job running
    jobs.each do |job|
      if job['state'] != 'running'
        job.delete
      else
	    job['assigned_nodes'].group_by{ |node_id| node_id.split("-")[0] }.each{|cluster_id, nodes|
       puts "
       Submitting deployment on #{cluster_id} nodes...
       "
       deployments<<job.parent.deployments.submit(:environment => "lenny-x64-base", :nodes => job['assigned_nodes'], :key => File.read(public_key)) rescue nil
	}
	k=job['assigned_nodes'].length
	n=n+k
	puts "ASSIGNED NODES:
	#{job['assigned_nodes'].pretty_inspect}
	
	#{k} new nodes are booked for the deployments...Total #{n}...

	"
      end
    end  
#END deployment

#Did we end up with no deployments? 
    deployments.compact!
    if deployments.empty?
      logger.warn "No deployments, exiting..."
      extinction.call
      exit(0)
      end
#END deployments inspect.

#start time out loop
    begin
      Timeout.timeout(60*15) do # wait at most 15mins
        until deployments.all?{|deployment| deployment['status'] == 'terminated'} do
          logger.info "
	  Some deployments are not terminated. Waiting 30 seconds before checking again...
	  "
          sleep 30
          deployments.each{|deployment| deployment.reload
      if deployment['status']=='terminated'
	      deployment['result'].each_key{|key| results_n.store(key, deployment['result']["#{key}"]['state'])}
	      puts "
	      
	      #{Time.new.strftime("%H:%M:%S")} Deployment on #{deployment["nodes"].first.split("-")[0]}'s #{deployment["nodes"].length} assigned nodes is terminated!!!!
	      "
	      
         
      else 
	      puts "Waiting for the deployment on #{deployment["nodes"].first.split("-")[0]}'s #{deployment["nodes"].length} assigned nodes to be terminated..."
      # puts "OK: #{deployment.pretty_inspect}"
      end
	}
	end
      end
    rescue Timeout::Error => e
      session.logger.warn "
      One of the deployments is still not terminated: it Will be deleted...
      "
    end
#END time out loop.

#Delete second deployments
n_message="SECOND DEPLOYMENT: ############ #{results_n.size} nodes deployed over #{n} initail deployment#########";
    deployments.each do |deployment|
	  #  puts "#{results_n.pretty_inspect}"
	    puts "
		#{n_message}
		"
        deployment.delete
	end
#END delete second deployments

puts "
#{m_message}
#{n_message}
"
end
rescue StandardError => e
  puts "Catched unexpected exception #{e.class.name}: #{e.message} - #{e.backtrace.join("\n")}"
  extinction.call
  exit(1)
end
