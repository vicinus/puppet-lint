class PuppetLint::Plugins::CheckClasses < PuppetLint::CheckPlugin
  # Public: Test the manifest tokens for any right-to-left (<-) chaining
  # operators and record a warning for each instance found.
  #
  # Returns nothing.
  check 'right_to_left_relationship' do
    tokens.select { |r| r.type == :OUT_EDGE }.each do |token|
      notify :warning, {
        :message    =>  'right-to-left (<-) relationship',
        :linenumber => token.line,
        :column     => token.column,
      }
    end
  end

  # Public: Test the manifest tokens for any classes or defined types that are
  # not in an appropriately named file for the autoloader to detect and record
  # an error of each instance found.
  #
  # Returns nothing.
  check 'autoloader_layout' do
    unless fullpath == ''
      (class_indexes + defined_type_indexes).each do |class_idx|
        class_tokens = tokens[class_idx[:start]..class_idx[:end]]
        title_token = class_tokens[class_tokens.index { |r| r.type == :NAME }]
        split_title = title_token.value.split('::')
        mod = split_title.first
        if split_title.length > 1
          expected_path = "#{mod}/manifests/#{split_title[1..-1].join('/')}.pp"
        else
          expected_path = "#{title_token.value}/manifests/init.pp"
        end

        unless fullpath.end_with? expected_path
          notify :error, {
            :message    => "#{title_token.value} not in autoload module layout",
            :linenumber => title_token.line,
            :column     => title_token.column,
          }
        end
      end
    end
  end

  # Public: Test the manifest tokens for any parameterised classes or defined
  # types that take parameters and record a warning if there are any optional
  # parameters listed before required parameters.
  #
  # Returns nothing.
  check 'parameter_order' do
    (class_indexes + defined_type_indexes).each do |class_idx|
      token_idx = class_idx[:start]
      depth = 0
      lparen_idx = nil
      rparen_idx = nil
      tokens[token_idx..-1].each_index do |t|
        idx = token_idx + t
        if tokens[idx].type == :LPAREN
          depth += 1
          lparen_idx = idx if depth == 1
        elsif tokens[idx].type == :RPAREN
          depth -= 1
          if depth == 0
            rparen_idx = idx
            break
          end
        end
      end

      unless lparen_idx.nil? or rparen_idx.nil?
        param_tokens = tokens[lparen_idx+1..rparen_idx-1].reject { |r|
          formatting_tokens.include? r.type
        }

        paren_stack = []
        param_tokens.each_index do |param_tokens_idx|
          this_token = param_tokens[param_tokens_idx]
          next_token = param_tokens[param_tokens_idx+1]
          prev_token = param_tokens[param_tokens_idx-1]

          if this_token.type == :LPAREN
            paren_stack.push(true)
          elsif this_token.type == :RPAREN
            paren_stack.pop
          end
          next unless paren_stack.empty?

          if this_token.type == :VARIABLE
            if next_token.nil? || next_token.type == :COMMA
              prev_tokens = param_tokens[0..param_tokens_idx]
              unless prev_tokens.rindex { |r| r.type == :EQUALS }.nil?
                unless prev_token.nil? or prev_token.type == :EQUALS
                  msg = 'optional parameter listed before required parameter'
                  notify :warning, {
                    :message    => msg,
                    :linenumber => this_token.line,
                    :column     => this_token.column,
                  }
                end
              end
            end
          end
        end
      end
    end
  end

  # Public: Test the manifest tokens for any classes that inherit across
  # namespaces and record a warning for each instance found.
  #
  # Returns nothing.
  check 'inherits_across_namespaces' do
    class_indexes.each do |class_idx|
      class_tokens = tokens[class_idx[:start]..class_idx[:end]].reject { |r|
        formatting_tokens.include?(r.type)
      }

      if class_tokens[2].type == :INHERITS
        class_name = class_tokens[1].value
        inherited_class = class_tokens[3].value

        unless class_name =~ /^#{inherited_class}::/
          notify :warning, {
            :message    => "class inherits across namespaces",
            :linenumber => class_tokens[3].line,
            :column     => class_tokens[3].column,
          }
        end
      end
    end
  end

  # Public: Test the manifest tokens for any classes or defined types that are
  # defined inside another class.
  #
  # Returns nothing.
  check 'nested_classes_or_defines' do
    class_indexes.each do |class_idx|
      # Skip the first token so that we don't pick up the first :CLASS
      class_tokens = tokens[class_idx[:start]+1..class_idx[:end]].reject { |r|
        formatting_tokens.include?(r.type)
      }

      class_tokens.each_index do |token_idx|
        token = class_tokens[token_idx]
        next_token = class_tokens[token_idx + 1]

        if token.type == :CLASS
          if next_token.type != :LBRACE
            notify :warning, {
              :message    => "class defined inside a class",
              :linenumber => token.line,
              :column     => token.column,
            }
          end
        end

        if token.type == :DEFINE
          notify :warning, {
            :message    => "define defined inside a class",
            :linenumber => token.line,
            :column     => token.column,
          }
        end
      end
    end
  end

  # Public: Test the manifest tokens for any variables that are referenced in
  # the manifest.  If the variables are not fully qualified or one of the
  # variables automatically created in the scope, check that they have been
  # defined in the local scope and record a warning for each variable that has
  # not.
  #
  # Returns nothing.
  check 'variable_scope' do
    variables_in_scope = [
      'name',
      'title',
      'module_name',
      'environment',
      'clientcert',
      'clientversion',
      'servername',
      'serverip',
      'serverversion',
      'caller_module_name',
    ]
    (class_indexes + defined_type_indexes).each do |idx|
      object_tokens = tokens[idx[:start]..idx[:end]]
      object_tokens.reject! { |r| formatting_tokens.include?(r.type) }
      depth = 0
      lparen_idx = nil
      rparen_idx = nil
      object_tokens.each_index do |t|
        if object_tokens[t].type == :LPAREN
          depth += 1
          lparen_idx = t if depth == 1
        elsif object_tokens[t].type == :RPAREN
          depth -= 1
          if depth == 0
            rparen_idx = t
            break
          end
        end
      end
      referenced_variables = []

      unless lparen_idx.nil? or rparen_idx.nil?
        param_tokens = object_tokens[lparen_idx..rparen_idx]
        param_tokens.each_index do |param_tokens_idx|
          this_token = param_tokens[param_tokens_idx]
          next_token = param_tokens[param_tokens_idx+1]
          if this_token.type == :VARIABLE
            if [:COMMA, :EQUALS, :RPAREN].include? next_token.type
              variables_in_scope << this_token.value
            end
          end
        end
      end

      object_tokens.each_index do |object_token_idx|
        this_token = object_tokens[object_token_idx]
        next_token = object_tokens[object_token_idx + 1]

        if this_token.type == :VARIABLE
          if next_token.type == :EQUALS
            variables_in_scope << this_token.value
          else
            referenced_variables << this_token
          end
        end
      end

      msg = "top-scope variable being used without an explicit namespace"
      referenced_variables.each do |token|
        unless token.value.include? '::'
          unless variables_in_scope.include? token.value
            unless token.value =~ /\d+/
              notify :warning, {
                :message    => msg,
                :linenumber => token.line,
                :column     => token.column,
              }
            end
          end
        end
      end
    end
  end
end
