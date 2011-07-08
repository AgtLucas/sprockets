require 'sprockets/asset'
require 'sprockets/errors'
require 'fileutils'
require 'set'
require 'zlib'

module Sprockets
  # `BundledAsset`s are used for files that need to be processed and
  # concatenated with other assets. Use for `.js` and `.css` files.
  class BundledAsset < Asset
    # Define extra attributes to be serialized.
    def self.serialized_attributes
      super + %w( content_type mtime )
    end

    def initialize(environment, logical_path, pathname, options)
      super(environment, logical_path, pathname)
      @options = options || {}
    end

    # Initialize `BundledAsset` from serialized `Hash`.
    def init_with(environment, coder)
      @options = {}

      @length = coder['length']
      @digest = coder['digest']
      @source = coder['source']

      super

      @body   = coder['body']
      @assets = coder['asset_paths'].map { |p|
        p = expand_root_path(p)
        p == pathname.to_s ? self : environment[p, @options]
      }

      @dependency_files = coder['dependency_files'].map { |h|
        h.merge('path' => expand_root_path(h['path']))
      }
      @dependency_files.each do |dep|
        dep['mtime'] = Time.parse(dep['mtime']) if dep['mtime'].is_a?(String)
      end
    end

    # Serialize custom attributes in `BundledAsset`.
    def encode_with(coder)
      coder['length'] = length
      coder['digest'] = digest
      coder['source'] = to_s

      super

      coder['body']        = body
      coder['asset_paths'] = to_a.map { |a| relativize_root_path(a.pathname) }
      coder['dependency_files'] = dependency_files.map { |h|
        h.merge('path' => relativize_root_path(h['path']))
      }
    end

    # Get asset's own processed contents. Excludes any of its required
    # dependencies but does run any processors or engines on the
    # original file.
    def body
      @body ||= dependency_context_and_body[1]
    end

    # Get latest mtime of all its dependencies.
    def mtime
      @mtime ||= dependency_files.map { |h| h['mtime'] }.max
    end

    # Get size of concatenated source.
    def length
      @length ||= Rack::Utils.bytesize(to_s)
    end

    # Compute digest of concatenated source.
    def digest
      @digest ||= environment.digest.update(to_s).hexdigest
    end

    # Return an `Array` of `Asset` files that are declared dependencies.
    def dependencies
      to_a - [self]
    end

    # Expand asset into an `Array` of parts.
    def to_a
      @assets ||= compute_assets
    end

    # Checks if Asset is stale by comparing the actual mtime and
    # digest to the inmemory model.
    def fresh?
      # Check freshness of all declared dependencies
      dependency_files.all? { |h| dependency_fresh?(h) }
    end

    # Return `String` of concatenated source.
    def to_s
      @source ||= build_source
    end

    # Save asset to disk.
    def write_to(filename, options = {})
      # Gzip contents if filename has '.gz'
      options[:compress] ||= File.extname(filename) == '.gz'

      File.open("#{filename}+", 'wb') do |f|
        if options[:compress]
          # Run contents through `Zlib`
          gz = Zlib::GzipWriter.new(f, Zlib::BEST_COMPRESSION)
          gz.write to_s
          gz.close
        else
          # Write out as is
          f.write to_s
          f.close
        end
      end

      # Atomic write
      FileUtils.mv("#{filename}+", filename)

      # Set mtime correctly
      File.utime(mtime, mtime, filename)

      nil
    ensure
      # Ensure tmp file gets cleaned up
      FileUtils.rm("#{filename}+") if File.exist?("#{filename}+")
    end

    protected
      # Return new blank `Context` to evaluate processors in.
      def blank_context
        environment.context_class.new(environment, logical_path.to_s, pathname)
      end

      def dependency_context_and_body
        @dependency_context_and_body ||= build_dependency_context_and_body
      end

      # Get `Context` after processors have been ran on it. This
      # trackes any dependencies that processors have added to it.
      def dependency_context
        dependency_context_and_body[0]
      end

      # All files that this asset depends on. This list may include
      # non-assets like directories.
      def dependency_files
        @dependency_files ||= dependency_context._dependency_paths.to_a.map do |path|
          { 'path'      => path,
            'mtime'     => environment.stat(path).mtime,
            'hexdigest' => environment.file_digest(path).hexdigest }
        end
      end

    private
      # Check if self has already been required and raise a fast
      # error. Otherwise you end up with a StackOverflow error.
      def check_circular_dependency!
        requires = @options[:_requires] ||= []
        if requires.include?(pathname.to_s)
          raise CircularDependencyError, "#{pathname} has already been required"
        end
        requires << pathname.to_s
      end

      def build_dependency_context_and_body
        context = blank_context

        # Read original data once and pass it along to `Context`
        data = Sprockets::Utils.read_unicode(pathname)

        # Prime digest cache with data, since we happen to have it
        environment.file_digest(pathname, data)

        # Runs all processors on `Context`
        body = context.evaluate(pathname, :data => data)

        return context, body
      end

      def build_source
        data = ""

        # Explode Asset into parts and gather the dependency bodies
        to_a.each { |dependency| data << dependency.body }

        # Run bundle processors on concatenated source
        blank_context.evaluate(pathname, :data => data,
          :processors => environment.bundle_processors(content_type))
      end

      def compute_assets
        check_circular_dependency!

        assets = []

        # Define an `add_dependency` helper
        add_dependency = lambda do |asset|
          unless assets.any? { |a| a.pathname == asset.pathname }
            assets << asset
          end
        end

        # Iterate over all the declared require paths from the `Context`
        dependency_context._required_paths.each do |required_path|
          # Catch `require_self`
          if required_path == pathname.to_s
            add_dependency.call(self)
          else
            # Recursively lookup required asset
            environment[required_path, @options].to_a.each do |asset|
              add_dependency.call(asset)
            end
          end
        end

        # Ensure self is added to the dependency list
        add_dependency.call(self)

        assets
      end
  end
end
