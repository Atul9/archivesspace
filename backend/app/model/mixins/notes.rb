require 'securerandom'
require_relative 'auto_generator'
require_relative '../note'

module Notes

  def self.included(base)
    base.one_to_many :note

    Note.many_to_one base.table_name

    base.extend(ClassMethods)
  end


  def update_from_json(json, opts = {}, apply_nested_records = true)
    obj = super
    self.class.apply_notes(obj, json)
  end


  def persistent_id_context
    if self.respond_to?(:root_record_id) && self.root_record_id
      parent_id = self.root_record_id
      parent_type = self.class.root_record_type.to_s
    else
      parent_id = self.id
      parent_type = self.class.my_jsonmodel.record_type
    end

    [parent_id, parent_type]
  end


  module ClassMethods


    def populate_persistent_ids(json)
      json.notes.each do |note|
        JSONSchemaUtils.map_hash_with_schema(note, JSONModel(note['jsonmodel_type']).schema,
                                             [proc {|hash, schema|
                                                if schema['properties']['persistent_id']
                                                  hash['persistent_id'] ||= SecureRandom.hex
                                                end

                                                hash
                                              }])
      end
    end


    def extract_persistent_ids(note)
      result = []

      JSONSchemaUtils.map_hash_with_schema(note, JSONModel(note['jsonmodel_type']).schema,
                                           [proc {|hash, schema|
                                              if schema['properties']['persistent_id']
                                                result << hash['persistent_id']
                                              end

                                              hash
                                            }])

      result.compact
    end


    def apply_notes(obj, json)
      obj.note_dataset.delete

      populate_persistent_ids(json)

      json.notes.each do |note|
        publish = note['publish'] ? 1 : 0
        note.delete('publish')

        note_obj = Note.create(:notes_json_schema_version => json.class.schema_version,
                               :publish => publish,
                               :lock_version => 0,
                               :notes => JSON(note))

        # Persistent IDs exist in the context of the tree they belong to (or
        # just their record, if there's no tree).

        note_obj.add_persistent_ids(extract_persistent_ids(note),
                                    *obj.persistent_id_context)

        obj.add_note(note_obj)
      end

      obj
    end


    def create_from_json(json, opts = {})
      obj = super
      apply_notes(obj, json)
    end


    def resolve_note_component_references(obj, json)
      if obj.class.respond_to?(:node_record_type)
        klass = Kernel.const_get(obj.class.node_record_type.camelize)
        # If the object doesn't have a root record, it IS a root record.
        root_id = obj.respond_to?(:root_record_id) ? obj.root_record_id : obj.id

        json.notes.each do |note|
          JSONSchemaUtils.map_hash_with_schema(note, JSONModel(note['jsonmodel_type']).schema,
                                               [proc {|hash, schema|
                                                  if hash['jsonmodel_type'] == 'note_index'
                                                    hash["items"].each do |item|
                                                      referenced_record = klass.filter(:root_record_id => root_id,
                                                                                       :ref_id => item["reference"]).first
                                                      if !referenced_record.nil?
                                                        item["reference_ref"] = {"ref" => referenced_record.uri}
                                                      end
                                                    end
                                                  end

                                                  hash
                                                }])
        end
      end
    end


    def resolve_note_persistent_id_references(obj, json)
      json.notes.each do |note|
        JSONSchemaUtils.map_hash_with_schema(note, JSONModel(note['jsonmodel_type']).schema,
                                             [proc {|hash, schema|
                                                if hash['jsonmodel_type'] == 'note_index'
                                                  hash["items"].each do |item|
                                                    (parent_id, parent_type) = obj.persistent_id_context
                                                    persistent_id_record = NotePersistentId.filter(:parent_id => parent_id,
                                                                                                   :parent_type => parent_type,
                                                                                                   :persistent_id => item["reference"]).first
                                                    if !persistent_id_record.nil?
                                                      note = Note[persistent_id_record[:note_id]]

                                                      referenced_record = Note.associations.map {|association|
                                                        next if association == :note_persistent_id
                                                        note.send(association)
                                                      }.compact.first

                                                      if referenced_record
                                                        item["reference_ref"] = {"ref" => referenced_record.uri}
                                                      end
                                                    end
                                                  end
                                                end

                                                hash
                                              }])
      end
    end


    def resolve_note_references(obj, json)
      resolve_note_component_references(obj, json)
      resolve_note_persistent_id_references(obj, json)
    end


    def sequel_to_jsonmodel(obj, opts = {})
      notes = Array(obj.note.sort_by {|note| note[:id]}).map {|note|
        parsed = ASUtils.json_parse(note.notes)
        parsed['publish'] = (note.publish == 1)
        parsed
      }

      json = super
      json.notes = notes

      resolve_note_references(obj, json)

      json
    end


    def calculate_object_graph(object_graph, opts = {})
      super

      column = "#{self.table_name}_id".intern

      ids = Note.filter(column => object_graph.ids_for(self)).
                 map {|row| row[:id]}

      object_graph.add_objects(Note, ids)
    end

  end
end
