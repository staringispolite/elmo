# Holds behaviors related to standard objects including re-replication, importing, etc.
# All Standardizable objects are assumed to be Replicable also.
module Standardizable
  extend ActiveSupport::Concern

  # list of class names whose changes should be replicated on save
  CLASSES_TO_REREPLICATE = %w(Form Question Questioning OptionSet OptionNode Option)

  included do
    # create a flag to use with the callback below
    attr_accessor :changing_in_replication

    # create self-associations in both directions for is-copy-of relationship
    belongs_to(:standard, :class_name => name, :inverse_of => :copies)
    has_many(:copies, :class_name => name, :foreign_key => 'standard_id', :inverse_of => :standard)

    # create hooks to copy key params from parent and to children
    # this doesn't work with before_create for some reason
    before_validation(:copy_is_standard_and_mission_from_parent)
    before_validation(:copy_is_standard_and_mission_to_children)

    validates(:mission_id, :presence => true, :unless => ->(o) {o.is_standard?})

    # returns a scope for all standard objects of the current class that are importable to the given mission
    # (i.e. that don't already exist in that mission)
    def self.importable_to(mission)
      # get ids of all standard objs already copied to the mission
      existing_ids = for_mission(mission).where('standard_id IS NOT NULL').map(&:standard_id)

      # build relation
      rel = where(:is_standard => true)
      rel = rel.where("id NOT IN (?)", existing_ids) unless existing_ids.empty?
      rel
    end
  end

  def save_and_rereplicate(method = 'save')
    # If any of this fails it should all fail.
    transaction do
      Thread.current[:elmo_capturing_changes?] = true
      result = send(method)
      Thread.current[:elmo_capturing_changes?] = false
      rereplicate_to_copies
      do_assertions
      result
    end
  end

  def save_and_rereplicate!
    save_and_rereplicate('save!')
  end

  def destroy_with_copies
    transaction do
      destroy_copies
      destroy
      do_assertions
    end
  end

  # get copy in the given mission, if it exists (there can only be one)
  # (we can assume that all standardizable classes are also mission-based)
  def copy_for_mission(mission)
    copies.for_mission(mission).first
  end

  # returns whether the object is standard or related to a standard object
  def standardized?
    is_standard? || standard_copy?
  end

  def standard_copy?
    standard.present?
  end

  # adds an obj to the list of copies
  def add_copy(obj)
    # don't add if already there
    copies << obj unless copies.include?(obj)
  end

  # returns number of copies, or zero if this obj is not standard
  # uses eager loaded field if available
  def copy_count
    is_standard? ? (respond_to?(:copy_count_col) ? copy_count_col : copies.count) : 0
  end

  private

    # replicates the current object (if standard) to each of its copies to ensure any changes are propagated
    def rereplicate_to_copies
      return unless is_standard?

      # don't replicate changes arising from the replication process itself, as this leads to an infinite loop
      if changing_in_replication
        changing_in_replication = false
      else
        if self.class.log_replication?
          lines = []
          lines << "***** RE-REPLICATING TO COPIES AFTER SAVING STANDARD ***********************************"
          lines << "Source obj: #{self}"
          Rails.logger.debug(lines.join("\n"))
        end

        # we only need to rereplicate on certain classes
        if CLASSES_TO_REREPLICATE.include?(self.class.name)
          # if we just run replicate for each copy's mission, all changes will be propagated
          copies(true).each{|c| replicate(:mode => :to_mission, :dest_mission => c.mission)}
        end
      end
    end

    # destroys all copies of this standard object
    def destroy_copies
      return unless is_standard?

      if self.class.log_replication?
        lines = []
        lines << "***** DESTROYING COPIES BEFORE DESTROYING STANDARD ***************************************"
        lines << "Source obj:   #{self}"
        Rails.logger.debug(lines.join("\n"))
      end

      copies(true).each{|c| c.destroy}
    end

    # copies the is_standard and mission properties from any parent association
    def copy_is_standard_and_mission_from_parent
      # reflect on parent association, if it exists
      parent_assoc = self.class.reflect_on_association(self.class.replication_options[:parent_assoc])

      # if the parent association exists and is a belongs_to association and parent exists
      # (e.g. questioning has parent = form, and a form association exists, and parent exists)
      if parent_assoc.try(:macro) == :belongs_to && parent = self.send(parent_assoc.name)
        # copy the params
        self.is_standard = parent.is_standard?
        self.mission = parent.mission
      end
      return true
    end

    # copies the is_standard and mission properties to any children associations
    def copy_is_standard_and_mission_to_children
      # iterate over children assocs
      self.class.replication_options[:child_assocs].each do |assoc|
        refl = self.class.reflect_on_association(assoc)

        # if is a collection association, copy to each, else copy to individual
        if refl.collection?
          send(assoc).each do |o|
            o.is_standard = is_standard?
            o.mission = mission
          end
        else
          unless send(assoc).nil?
            send(assoc).is_standard = is_standard?
            send(assoc).mission = mission
          end
        end
      end
      return true
    end

    # Runs some assertions against the database and raises an error if they fail so that the cause
    # can be investigated.
    def do_assertions
      assert_no_results('select s.form_id, s.id, s.rank, c.id, c.rank
        from questionings s left outer join questionings c on c.standard_id = s.id
        where s.rank != c.rank order by s.form_id, s.rank',
        'misaligned ranks between standard and copies')

      assert_no_results('select s.form_id, s.id, s.rank, c.id, c.rank
        from questionings s left outer join questionings c on c.standard_id = s.id
        where c.id is null and s.form_id in (
          select distinct sf.id from forms sf inner join forms sc on sf.id = sc.standard_id
        ) order by s.form_id, s.rank',
        'questionings from copied standard forms dont have corresponding copies')
    end

    # Raises an error if the given sql returns any results.
    def assert_no_results(sql, msg)
      raise "Assertion failed: #{msg}" unless self.class.find_by_sql(sql).empty?
    end
end
