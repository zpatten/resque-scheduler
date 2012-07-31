require 'rubygems'
require 'resque'
require 'resque_scheduler/version'
require 'resque/scheduler'
require 'resque_scheduler/plugin'

module ResqueScheduler

  #
  # Accepts a new schedule configuration of the form:
  #
  #   {
  #     "MakeTea" => {
  #       "every" => "1m" },
  #     "some_name" => {
  #       "cron"        => "5/* * * *",
  #       "class"       => "DoSomeWork",
  #       "args"        => "work on this string",
  #       "description" => "this thing works it"s butter off" },
  #     ...
  #   }
  #
  # Hash keys can be anything and are used to describe and reference
  # the scheduled job. If the "class" argument is missing, the key
  # is used implicitly as "class" argument - in the "MakeTea" example,
  # "MakeTea" is used both as job name and resque worker class.
  #
  # :cron can be any cron scheduling string
  #
  # :every can be used in lieu of :cron. see rufus-scheduler's 'every' usage
  # for valid syntax. If :cron is present it will take precedence over :every.
  #
  # :class must be a resque worker class. If it is missing, the job name (hash key)
  # will be used as :class.
  #
  # :args can be any yaml which will be converted to a ruby literal and
  # passed in a params. (optional)
  #
  # :rails_envs is the list of envs where the job gets loaded. Envs are
  # comma separated (optional)
  #
  # :description is just that, a description of the job (optional). If
  # params is an array, each element in the array is passed as a separate
  # param, otherwise params is passed in as the only parameter to perform.
  def schedule=(schedule_hash)
    schedule_hash = prepare_schedule(schedule_hash)

    if Resque::Scheduler.dynamic
      schedule_hash.each do |name, job_spec|
        set_schedule(name, job_spec)
      end
    end
    @schedule = schedule_hash
  end

  # Returns the schedule hash
  def schedule
    @schedule ||= {}
  end

  # reloads the schedule from redis
  def reload_schedule!
    @schedule = get_schedules
  end

  # gets the schedule as it exists in redis
  def get_schedules
    if redis.exists(:schedules)
      redis.hgetall(:schedules).tap do |h|
        h.each do |name, config|
          h[name] = decode(config)
        end
      end
    else
      nil
    end
  end

  # Create or update a schedule with the provided name and configuration.
  #
  # Note: values for class and custom_job_class need to be strings,
  # not constants.
  #
  #    Resque.set_schedule('some_job', {:class => 'SomeJob',
  #                                     :every => '15mins',
  #                                     :queue => 'high',
  #                                     :args => '/tmp/poop'})
  def set_schedule(name, config)
    existing_config = get_schedule(name)
    unless existing_config && existing_config == config
      redis.hset(:schedules, name, encode(config))
      redis.sadd(:schedules_changed, name)
    end
    config
  end

  # retrive the schedule configuration for the given name
  def get_schedule(name)
    decode(redis.hget(:schedules, name))
  end

  # remove a given schedule by name
  def remove_schedule(name)
    redis.hdel(:schedules, name)
    redis.sadd(:schedules_changed, name)
  end

  # This method is nearly identical to +enqueue+ only it also
  # takes a timestamp which will be used to schedule the job
  # for queueing.  Until timestamp is in the past, the job will
  # sit in the schedule list.
  def enqueue_at(timestamp, klass, *args)
    validate_job!(klass)
    enqueue_at_with_queue(queue_from_class(klass), timestamp, klass, *args)
  end

  # Identical to +enqueue_at+, except you can also specify
  # a queue in which the job will be placed after the
  # timestamp has passed. It respects Resque.inline option, by
  # creating the job right away instead of adding to the queue.
  def enqueue_at_with_queue(queue, timestamp, klass, *args)
    return false unless Plugin.run_before_schedule_hooks(klass, *args)

    if Resque.inline?
      # Just create the job and let resque perform it right away with inline.
      Resque::Job.create(queue, klass, *args)
    else
      delayed_push(timestamp, job_to_hash_with_queue(queue, klass, args))
    end

    Plugin.run_after_schedule_hooks(klass, *args)
  end

  # Identical to enqueue_at but takes number_of_seconds_from_now
  # instead of a timestamp.
  def enqueue_in(number_of_seconds_from_now, klass, *args)
    enqueue_at(Time.now + number_of_seconds_from_now, klass, *args)
  end

  # Identical to +enqueue_in+, except you can also specify
  # a queue in which the job will be placed after the
  # number of seconds has passed.
  def enqueue_in_with_queue(queue, number_of_seconds_from_now, klass, *args)
    enqueue_at_with_queue(queue, Time.now + number_of_seconds_from_now, klass, *args)
  end

  # Used internally to stuff the item into the schedule sorted list.
  # +timestamp+ can be either in seconds or a datetime object
  # Insertion if O(log(n)).
  # Returns true if it's the first job to be scheduled at that time, else false
  def delayed_push(timestamp, item)
    encoded_item = encode(item)
    existing_delayed_items = redis.zrangebyscore(:delayed_queue_schedule, timestamp.to_i, timestamp.to_i)
    if existing_delayed_items.none?{ |edi| edi == encoded_item }
      # First add this item to the list for this timestamp
      redis.rpush("delayed:#{timestamp.to_i}", encoded_item)

      # Now, add this timestamp to the zsets.  The score and the value are
      # the same since we'll be querying by timestamp, and we don't have
      # anything else to store.
      redis.zadd(:delayed_queue_schedule, timestamp.to_i, encoded_item)
    end
  end

  # Returns an array of timestamps based on start and count
  def delayed_queue_peek(start, count)
    Array(redis.zrange(:delayed_queue_schedule, start, start+count-1, :withscores => true)).collect{ |item, timestamp| timestamp.to_i }
  end

  # Returns the size of the delayed queue schedule
  def delayed_queue_schedule_size
    redis.zcard(:delayed_queue_schedule)
  end

  # Returns the number of jobs for a given timestamp in the delayed queue schedule
  def delayed_timestamp_size(timestamp)
    redis.llen("delayed:#{timestamp.to_i}").to_i
  end

  # Returns an array of delayed items for the given timestamp
  def delayed_timestamp_peek(timestamp, start, count)
    if 1 == count
      r = list_range("delayed:#{timestamp.to_i}", start, count)
      r.nil? ? [] : [r]
    else
      list_range("delayed:#{timestamp.to_i}", start, count)
    end
  end

  # Returns the next delayed queue timestamp
  # (don't call directly)
  def next_delayed_timestamp(at_time=nil)
    items = redis.zrangebyscore(:delayed_queue_schedule, '-inf', (at_time || Time.now).to_i, :withscores => true, :limit => [0, 1]).collect{ |item, timestamp| timestamp.to_i }
    puts "ITEMS: #{items.inspect}"
    timestamp = items.nil? ? nil : Array(items).first
    puts "TIMESTAMP: #{timestamp.inspect}"
    timestamp.to_i unless timestamp.nil?
  end

  # Returns the next item to be processed for a given timestamp, nil if
  # done. (don't call directly)
  # +timestamp+ can either be in seconds or a datetime
  def next_item_for_timestamp(timestamp)
    key = "delayed:#{timestamp.to_i}"

    puts "KEY: #{key.inspect}"
    encoded_item = redis.lpop(key)
    item = decode(encoded_item)
    puts "ITEM: #{item.inspect}"

    # If the list is empty, remove it.
    clean_up_job(key, encoded_item)
    item
  end

  # Clears all jobs created with enqueue_at or enqueue_in
  def reset_delayed_queue
    redis.zrange(:delayed_queue_schedule, 0, -1, :withscores => true).each do |item, timestamp|
      redis.del("delayed:#{timestamp.to_i}")
    end

    redis.del(:delayed_queue_schedule)
  end

  # Given an encoded item, remove it from the delayed_queue
  #
  # This method is potentially very expensive since it needs to scan
  # through the delayed queue for every timestamp.
  def remove_delayed(klass, *args)
    destroyed = 0
    search = encode(job_to_hash(klass, args))
    Array(redis.keys("delayed:*")).each do |key|
      destroyed += redis.lrem(key, 0, search)
    end
    destroyed
  end

  # Given a timestamp and job (klass + args) it removes all instances and
  # returns the count of jobs removed.
  #
  # O(N) where N is the number of jobs scheduled to fire at the given
  # timestamp
  def remove_delayed_job_from_timestamp(timestamp, klass, *args)
    key = "delayed:#{timestamp.to_i}"
    item = encode(job_to_hash(klass, args))
    count = redis.lrem(key, 0, item)
    clean_up_job(key, item)
    count
  end

  def count_all_scheduled_jobs
    total_jobs = 0
    Array(redis.zrange(:delayed_queue_schedule, 0, -1, :withscores => true)).each do |item, timestamp|
      total_jobs += redis.llen("delayed:#{timestamp}").to_i
    end
    total_jobs
  end

  private

    def job_to_hash(klass, args)
      {:class => klass.to_s, :args => args, :queue => queue_from_class(klass)}
    end

    def job_to_hash_with_queue(queue, klass, args)
      {:class => klass.to_s, :args => args, :queue => queue}
    end

    def clean_up_job(key, job)
      puts "clean_up_job: #{key} | #{job}"
      # If the list is empty, remove it.
      redis.watch(key)
      puts "redis.llen == #{redis.llen(key).to_i}"
      if 0 == redis.llen(key).to_i
        redis.multi do
          redis.del(key)
          redis.zrem(:delayed_queue_schedule, job)
        end
      else
        redis.unwatch
      end
    end

    def validate_job!(klass)
      if klass.to_s.empty?
        raise Resque::NoClassError.new("Jobs must be given a class.")
      end

      unless queue_from_class(klass)
        raise Resque::NoQueueError.new("Jobs must be placed onto a queue.")
      end
    end

    def prepare_schedule(schedule_hash)
      prepared_hash = {}
      schedule_hash.each do |name, job_spec|
        job_spec = job_spec.dup
        job_spec['class'] = name unless job_spec.key?('class') || job_spec.key?(:class)
        prepared_hash[name] = job_spec
      end
      prepared_hash
    end

end

Resque.extend ResqueScheduler
