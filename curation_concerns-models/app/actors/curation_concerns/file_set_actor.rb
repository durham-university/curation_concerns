module CurationConcerns
  # Actions are decoupled from controller logic so that they may be called from a controller or a background job.
  class FileSetActor
    include CurationConcerns::ManagesEmbargoesActor
    include CurationConcerns::Lockable

    attr_reader :file_set, :user, :attributes, :curation_concern

    def initialize(file_set, user)
      # we're setting attributes and curation_concern to bridge the difference
      # between CurationConcerns::FileSetActor and ManagesEmbargoesActor
      @curation_concern = file_set
      @file_set = file_set
      @user = user
    end

    # Adds the appropriate metadata, visibility and relationships to file_set
    #
    # *Note*: In past versions of Sufia this method did not perform a save because it is mainly used in conjunction with
    # create_content, which also performs a save.  However, due to the relationship between Hydra::PCDM objects,
    # we have to save both the parent work and the file_set in order to record the "metadata" relationship
    # between them.
    # @param [ActiveFedora::Base] work the parent work that will contain the file_set.
    # @param [Hash] file_set specifying the visibility, lease and/or embargo of the file set.  If you don't provide at least one of visibility, embargo_release_date or lease_expiration_date, visibility will be copied from the parent.

    def create_metadata(work, file_set_params = {})
      file_set.apply_depositor_metadata(user)
      now = CurationConcerns::TimeService.time_in_utc
      file_set.date_uploaded = now
      file_set.date_modified = now
      file_set.creator = [user.user_key]

      interpret_visibility file_set_params if assign_visibility?(file_set_params)
      attach_file_to_work(work, file_set, file_set_params) if work
      yield(file_set) if block_given?
    end

    # Puts the uploaded content into a staging directory. Then kicks off a
    # job to characterize and create derivatives with this on disk variant.
    # Simultaneously moving a preservation copy to the repostiory.
    # TODO: create a job to monitor this directory and prune old files that
    # have made it to the repo
    # @param [File, ActionDigest::HTTP::UploadedFile, Tempfile] file the file uploaded by the user.
    def create_content(file)
      # Assign label and title of File Set is necessary.
      file_set.label ||= file.respond_to?(:original_filename) ? file.original_filename : ::File.basename(file)
      file_set.title = [file_set.label] if file_set.title.blank?

      # Need to save the file_set in order to get an id
      return false unless file_set.save

      working_file = copy_file_to_working_directory(file, file_set.id)
      mime_type = file.respond_to?(:content_type) ? file.content_type : nil
      IngestFileJob.perform_later(file_set.id, working_file, mime_type, user.user_key)
      make_derivative(file_set.id, working_file)
      true
    end

    def revert_content(revision_id)
      file_set.original_file.restore_version(revision_id)

      return false unless file_set.save

      CurationConcerns::VersioningService.create(file_set.original_file, user)

      # Retrieve a copy of the orginal file from the repository
      working_file = copy_repository_resource_to_working_directory(file_set)
      make_derivative(file_set.id, working_file)

      CurationConcerns.config.callback.run(:after_revert_content, file_set, user, revision_id)
      true
    end

    def update_content(file)
      working_file = copy_file_to_working_directory(file, file_set.id)
      IngestFileJob.perform_later(file_set.id, working_file, file.content_type, user.user_key)
      make_derivative(file_set.id, working_file)
      CurationConcerns.config.callback.run(:after_update_content, file_set, user)
      true
    end

    def update_metadata(attributes)
      update_visibility(attributes)
      # attributes.delete(:visibility) # Applying this attribute is handled by update_visibility
      file_set.attributes = attributes
      file_set.date_modified = CurationConcerns::TimeService.time_in_utc
      save do
        CurationConcerns.config.callback.run(:after_update_metadata, file_set, user)
      end
    end

    def destroy
      file_set.destroy
      CurationConcerns.config.callback.run(:after_destroy, file_set.id, user)
    end

    private

      def make_derivative(file_set_id, working_file)
        CharacterizeJob.perform_later(file_set_id, working_file)
      end

      # @param [File, ActionDispatch::Http::UploadedFile] file
      # @param [String] id the identifer
      # @return [String] path of the working file
      def copy_file_to_working_directory(file, id)
        # file_set.label not gaurunteed to be set at this point (e.g. if called from update_content)
        file_set.label ||= file.respond_to?(:original_filename) ? file.original_filename : ::File.basename(file)
        copy_stream_to_working_directory(id, file_set.label, file)
      end

      # @param [FileSet] file_set the resource
      # @return [String] path of the working file
      def copy_repository_resource_to_working_directory(file_set)
        file = file_set.original_file
        copy_stream_to_working_directory(file_set.id, file.original_name, StringIO.new(file.content))
      end

      # @param [String] id the identifer
      # @param [String] name the file name
      # @param [#read] stream the stream to copy to the working directory
      # @return [String] path of the working file
      def copy_stream_to_working_directory(id, name, stream)
        working_path = full_filename(id, name)
        FileUtils.mkdir_p(File.dirname(working_path))
        IO.copy_stream(stream, working_path)
        working_path
      end

      def full_filename(id, original_name)
        pair = id.scan(/..?/).first(4)
        File.join(CurationConcerns.config.working_path, *pair, original_name)
      end

      # Takes an optional block and executes the block if the save was successful.
      # returns false if the save was unsuccessful
      def save
        save_tries = 0
        begin
          return false unless file_set.save
        rescue RSolr::Error::Http => error
          ActiveFedora::Base.logger.warn "CurationConcerns::FileSetActor#save Caught RSOLR error #{error.inspect}"
          save_tries += 1
          # fail for good if the tries is greater than 3
          raise error if save_tries >= 3
          sleep 0.01
          retry
        end
        yield if block_given?
        true
      end

      # Adds a FileSet to the work using ore:Aggregations.
      # Locks to ensure that only one process is operating on
      # the list at a time.
      def attach_file_to_work(work, file_set, file_set_params)
        acquire_lock_for(work.id) do
          # Ensure we have an up-to-date copy of the members association, so
          # that we append to the end of the list.
          work.reload unless work.new_record?
          unless assign_visibility?(file_set_params)
            copy_visibility(work, file_set)
          end
          work.ordered_members << file_set
          set_representative(work, file_set)
          set_thumbnail(work, file_set)

          # Save the work so the association between the work and the file_set is persisted (head_id)
          work.save
        end
      end

      def assign_visibility?(file_set_params = {})
        !((file_set_params || {}).keys & %w(visibility embargo_release_date lease_expiration_date)).empty?
      end

      # This method can be overridden in case there is a custom approach for visibility (e.g. embargo)
      def update_visibility(attributes)
        interpret_visibility(attributes) # relies on CurationConcerns::ManagesEmbargoesActor to interpret and apply visibility
      end

      # copy visibility from source_concern to destination_concern
      def copy_visibility(source_concern, destination_concern)
        destination_concern.visibility =  source_concern.visibility
      end

      def set_representative(work, file_set)
        return unless work.representative_id.blank?
        work.representative = file_set
      end

      def set_thumbnail(work, file_set)
        return unless work.thumbnail_id.blank?
        work.thumbnail = file_set
      end
  end
end
