require 'rubygems'
require 'blather/client/dsl'
require 'json'
require 'mongo'

$: << File.dirname(__FILE__)+'/sail.rb/lib'
require 'sail/agent'

require 'model/student'

class Choreographer < Sail::Agent
  
  attr_accessor :mongo
  
  def initialize(*args)
    super(*args)
    @students = {} # cache of Choreographer::Student objects
  end
  
  def validate_student(stu)
    required_metadata = [
      #'meetup_1_topic',
      #'meetup_2_topic',
      'assigned_organisms',
      'specialty'
    ]
    
    required_metadata.each do |key|
      if stu.metadata.send("#{key}?".to_sym).nil? || stu.metadata.send("#{key}".to_sym).blank?
        raise "#{stu} is missing #{key.inspect}! Cannot continue :("
      end
    end
    
    begin
      orgs = JSON.parse(stu.metadata.assigned_organisms)
    rescue JSON::ParserError => e
      raise "Couldn't parse #{stu}'s assigned organisms -- invalid JSON!  #{e}"
    end
    
    if orgs.empty?
      raise "#{stu} does not have any animals assigned."
    end
    
    if stu.groups.length < 1
      raise "#{self} doesn't appear to be in a team! Cannot continue :("
    elsif stu.groups.length > 1
      raise "#{self} belongs to more than one group! Cannot continue :("
    end
  end
  
  def validate_agent
    stu_sm_events = Student.new(:metadata => {}).statemachine.events.values.collect{|ev| ev.name.to_sym}
    agent_events = self.registered_events.collect{|ev| ev[:type].to_sym}
    
    unless (stu_sm_events - agent_events).empty?
      # FIXME: why doesn't log output anything here? might be some IO + EM issue
      puts
      puts "WARNING: Events in Student statemachine not handled by the agent"
      puts " - " + (stu_sm_events - agent_events).join("\n - ")
    end
  end
  
  def spawn!
    super
    validate_agent
  end
  
  def behaviour
    when_ready do
      @mongo = Mongo::Connection.new.db(config[:database])
      Student.site = config[:sail][:rollcall][:url]
      Student.agent = self # give all Students managed by this Choreographer a reference to self
      
      join_room
      join_log_room
    end
    
    self_joined_log_room do |stanza|
      groupchat_logger_ready!
    end
    
    someone_joined_room do |stanza|
      stu = lookup_student(Util.extract_login(stanza.from), true) unless
        stanza.from == agent_jid_in_room
      
      if stu
        validate_student(stu)
        
        stu.save if stu.dirty?
        log "#{stu} joined #{config[:room]}"
      end
    end
    
    # for debugging/testing
    event :test_student_method? do |stanza, data|
      username = data['payload']['username']
      method = data['payload']['method']
      args = data['payload']['args']
      log "testing method #{method}"
      begin
        stu = lookup_student(username)
        if args.nil? || args.empty?
          result = stu.send(method)
        else
          result = stu.send(method, *args)
        end
        log "#{method}: #{result.inspect}", :DEBUG
      rescue => e
        log "#{method}: #{e}", :ERROR
        raise e
      end
    end
    
    # for debugging/testing
    event :student_state_override? do |stanza, data|
      username = data['payload']['username']
      stu = lookup_student(username)
      state = data['payload']['state']
      log "manually setting #{stu}'s state to #{state.inspect}"
      stu.metadata.state = state.intern
    end
    
    event :check_in? do |stanza, data|
      username = data['origin']
      lookup_student(username).check_in!(data['payload'].symbolize_keys)
    end
    event :observations_start? do |stanza, data|
      @students.each do |username, stu|
        stu.observations_start!
      end
    end
    event :location_assignment? do |stanza, data|
      username = data['payload']['username']
      location = data['payload']['location']
      lookup_student(username).location_assignment!(data['payload'].symbolize_keys)
    end
    event :organism_observation? do |stanza, data|
      username = data['origin']
      location = data['payload']['location']
      lookup_student(username).organism_observation!(data['payload'].symbolize_keys)
    end
    event :meetup_start? do |stanza, data|
      @students.each do |username, stu|
        stu.meetup_start!(data['payload'].symbolize_keys)
      end
    end
    event :note? do |stanza, data|
      username = data['origin']
      location = data['payload']['location']
      lookup_student(username).note!(data['payload'].symbolize_keys)
    end
    event :homework_assignment? do |stanza, data|
      @students.each do |username, stu|
        stu.homework_assignment!
      end
    end
    
    # 
    # meetup_start
    # organism_features
    # transition_to_present
    # organism_observation
    # location_assignment
    # feature_observations_start
    # observation_tabulation
    # check_in
    # homework_assignment
    # note
    # concept_discussion
    # observations_start
    # 

    # event :organisms_assignment? do |stanza, data|
    #   username = data['payload']['username']
    #   organisms = [ data['payload']['first_organism'], data['payload']['second_organism'] ]
    #   stu = lookup_student(username)
    #   stu.organisms_assignment!(organisms)
    # end
    
    event :organism_present? do |stanza, data|
      username = data['origin']
      
      first  = data['payload']['first_organism']
      second = data['payload']['second_organism']
      
      presence = {
        'organisms' => [
          {first['organism'] => first['present']},
          {second['organism'] => second['present']}
        ],
        'location' => data['payload']['location'],
        'timestamp' => data['timestamp'],
        'username' => username
      }
      
      lookup_student(username).organism_present!(presence)
    end
    
    event :rainforest_guess_submitted? do |stanza, data|
      username = data['origin']
      
      guess = data['payload']
      guess['timestamp'] = data['timestamp']
      guess['author'] = username
      guess['username'] = username
      
      stu = lookup_student(username)
      stu.rainforest_guess_submitted!(guess)
      
      stu.group_members.each do |m|
        unless m.account.login == username
          guess['username'] = m.account.login
          stu2 = lookup_student(m.account.login)
          stu2.rainforest_guess_submitted!(guess)
        end
      end
    end
    
    event :interviewees_assigned? do |stanza, data|
      username = data['payload']['username']
      
      first = data['payload']['first_interviewee']
      second = data['payload']['second_interviewee']
      log "handling interview assigned: first #{first.inspect} second #{second.inspect}"
      
      lookup_student(username).interviewees_assigned!(first, second)
    end
    
    event :interview_started? do |stanza, data|
      username = data['origin']
      
      lookup_student(username).interview_started!
    end
    
    
    event :interview_submitted? do |stanza, data|
      username = data['origin']
      
      lookup_student(username).interview_submitted!(data['payload'])
    end
    
    event :rankings_submitted? do |stanza, data|
      username = data['origin']
      
      lookup_student(username).rankings_submitted!(data['payload'])
    end
    
    event :rationale_assigned? do |stanza, data|
      username = data['payload']['username']
      rationale = data['payload']['question']
      
      lookup_student(username).rationale_assigned!(rationale)
    end
    
    event :rationale_submitted? do |stanza, data|
      username = data['origin']
      
      lookup_student(username).rationale_submitted!
    end
    
    event :final_guess_submitted? do |stanza, data|
      username = data['origin']
      
      lookup_student(username).final_guess_submitted!
    end
  end
  
  def start_step(username, step_id)
    stu = lookup_student(username)
    event!(:start_step, {:step_id => step_id, :username => username, :group_code => stu.group_code})
  end
  
  # def assign_organisms_to_student(stu)
  #   event!(:organisms_assignment, {
  #     :username => stu.username, 
  #     :first_organism => "foo", 
  #     :second_organism => "faa"
  #   })
  # end
  
  def assign_location_for_guess(stu)
    # TODO: crowd management
    
    location = stu.determine_next_location_for_guess
    
    event!(:location_assignment, {
      :go_to_location => location,
      :username => stu.username
    })
  end
  
  def fetch_group(id)
    Rollcall::Group.site = Student.site if Rollcall::Group.site.blank?
    Rollcall::Group.find(id)
  end
  
  def assign_tasks_to_group(group_code)
    log "Assigning tasks to group #{group_code.inspect}"
    
    group_members = fetch_group(group_code).members
    scribe_idx = rand(group_members.length)
    
    (0..group_members.size-1).each do |i|
      username = group_members[i].account.login
      
      if i == scribe_idx
        task = "scribe"
      else
        task = "other"
      end
      
      log "Assigning task '#{task.inspect}' to #{username.inspect}"
      
      event!(:task_assignment, {
        :task => task,
        :username => username
      })
    end
  end
  
  def assign_interviewees_to_student(stu)
    #{"eventType":"test_student_method","payload":{"username":"EliOtis","method":"determine_interviewees"}}
    
    interviewees = stu.determine_interviewees
    
    event!(:interviewees_assigned, {
      "username" => stu.username,
      "first_interviewee" => interviewees[0],
      "second_interviewee" => interviewees[1]
    })
  end
  
  def assign_rationale(stu)
    rationale = stu.determine_rationale
    
    event!(:rationale_assigned, {
      'question' => rationale,
      'username' => stu.username
    })
  end
  
  def lookup_student(username, restoring = false)
    stu = @students[username]
      
    if stu.nil?
      log "Looking up user #{username.inspect} in Rollcall..."
      
      begin
        stu = Student.find(username)
      rescue ActiveResource::ResourceNotFound
        log "#{username.inspect} not found in Rollcall..."
        return nil
      end
      
      unless stu.kind == "Student"
       log "#{username.inspect} is not a student; will be ignored."
       return nil
      end
      
      log "#{username.inspect} loaded in state #{stu.state}"
      
      @students[username] = stu
    elsif restoring # make sure the entry event gets triggered when we are restoring but not reloading
      stu_from_rollcall = Student.find(username)
      stu.state = stu_from_rollcall.state
    end
    
    stu.agent = self
    return stu
  end
  
  
end
