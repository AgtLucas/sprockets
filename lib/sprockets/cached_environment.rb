require 'sprockets/base'

module Sprockets
  # `Cached` is a special cached version of `Environment`.
  #
  # The expection is that all of its file system methods are cached
  # for the instances lifetime. This makes `Cached` much faster. This
  # behavior is ideal in production environments where the file system
  # is immutable.
  #
  # `Cached` should not be initialized directly. Instead use
  # `Environment#cached`.
  class CachedEnvironment < Base
    def initialize(environment)
      initialize_configuration(environment)

      @cache    = environment.cache
      @stats    = Hash.new { |h, k| h[k] = _stat(k) }
      @entries  = Hash.new { |h, k| h[k] = _entries(k) }
    end

    # No-op return self as cached environment.
    def cached
      self
    end
    alias_method :index, :cached

    # Internal: Cache Environment#entries
    alias_method :_entries, :entries
    def entries(path)
      @entries[path]
    end

    # Internal: Cache Environment#stat
    alias_method :_stat, :stat
    def stat(path)
      @stats[path]
    end

    protected
      def asset_hash_cache_key(filename, digest, options)
        [
          'asset-hash',
          VERSION,
          self.version,
          filename,
          digest,
          options
        ]
      end

      def asset_digest_cache_key(filename, options)
        [
          'asset-digest',
          VERSION,
          self.version,
          filename,
          options,
          file_hexdigest(filename),
          self.paths
        ]
      end

      # Cache asset building in memory and in persisted cache.
      def build_asset_hash(filename, options)
        digest_key = asset_digest_cache_key(filename, options)

        if digest = cache._get(digest_key)
          hash_key = asset_hash_cache_key(filename, digest, options)

          if hash = cache._get(hash_key)
            digest, paths = hash[:metadata].values_at(:dependency_digest, :dependency_paths)
            if dependencies_hexdigest(paths) == digest
              return hash
            end
          end
        end

        if hash = super
          cache._set(digest_key, hash[:digest])

          # Push into asset digest cache
          hash_key = asset_hash_cache_key(filename, hash[:digest], options)
          # cache._set(hash_key, hash)
          cache.fetch(hash_key) { hash }

          return hash
        end

        nil
      end

    private
      # Cache is immutable, any methods that try to clear the cache
      # should bomb.
      def mutate_config(*args)
        raise RuntimeError, "can't modify immutable cached environment"
      end
  end
end
