module CurationConcerns
  # A model name that provides routes that are namespaced to CurationConcerns,
  # without changing the param key.
  #
  # Example:
  #   name = CurationConcerns::Name.new(GenericWork)
  #   name.param_key
  #   # => 'generic_work'
  #   name.route_key
  #   # => 'curation_concerns_generic_works'
  #
  class Name < ActiveModel::Name
    def initialize(klass, namespace = nil, name = nil)
      super
      @route_key          = "curation_concerns_#{ActiveSupport::Inflector.pluralize(@param_key)}"
      @singular_route_key = ActiveSupport::Inflector.singularize(@route_key)
      @route_key << "_index" if @plural == @singular
    end
  end
end
