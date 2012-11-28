classdef (HandleCompatible) Cacheable  

    methods(Abstract)
        % return the cacheName to be used when instance 
        name = getCacheName(obj)

        % return the param to be used when caching
        param = getCacheParam(obj) 
    end

    methods % Methods which subclasses may wish to override 

        % return a cache manager instance
        function cm = getCacheManager(obj);
            cm = MatdbSettingsStore.getDefaultCacheManager();
        end

        function obj = prepareForCache(obj)
            obj = obj;
        end

        % obj is the object newly loaded from cache, preLoadObj is the object 
        % as it existed before loading from the cache. Transfering data from obj
        % to preLoadObj will occur automatically for handle classes AFTER this
        % function is called. preLoadObj is provided only if there is information
        % in the object before calling loadFromCache that you would like to copy
        % to the cache-loaded object obj.
        function obj = postLoadFromCache(obj, param, timestamp, preLoadObj)
            obj = obj;
        end

        % return the timestamp to be used when storing the cache,
        % typically now is sufficient
        function timestamp = getCacheTimestamp(obj)
            timestamp = now;
        end

        function timestamp = getCacheValidAfterTimestamp(obj)
            % when implementing this function, DO NOT store the reference timestamp
            % in an non-transient object property, or it will be reset to older
            % values when loading from cache (as the property value stored in the cached 
            % instance will be used)
            timestamp = -Inf;
        end

        function transferToHandle(src, dest)
            assert(isa(dest, class(src)), 'Class names must match exactly');

            meta = metaclass(src);
            propInfo = meta.PropertyList;
            for iProp = 1:length(propInfo)
                info = propInfo(iProp);
                name = info.Name;
                if info.Dependent && isempty(info.SetMethod)
                    continue;
                end
                if info.Transient || info.Constant
                    continue;
                end
                dest.(name) = src.(name);
            end
        end
    end

    methods
        function name = getFullCacheName(obj)
            name = [class(obj) '_' obj.getCacheName()];
        end

        function cache(obj)
            cm = obj.getCacheManager();
            name = obj.getFullCacheName();
            param = obj.getCacheParam();
            timestamp = obj.getCacheTimestamp();
            obj = obj.prepareForCache();

            debug('Cache save on %s\n', name);

            cm.saveData(name, param, obj, 'timestamp', timestamp);
        end

        function tf = hasCache(obj)
            cm = obj.getCacheManager();
            name = obj.getFullCacheName();
            param = obj.getCacheParam();
            timestampRef = obj.getCacheValidAfterTimestamp();
            tf = cm.hasCacheNewerThan(name, param, timestampRef);
        end

        function deleteCache(obj)
            cm = obj.getCacheManager();
            name = obj.getFullCacheName();
            param = obj.getCacheParam();
            cm.deleteCache(name, param);
        end

        function [obj timestamp] = loadFromCache(obj)
            cm = obj.getCacheManager();
            name = obj.getFullCacheName();
            param = obj.getCacheParam();
            
            timestampRef = obj.getCacheValidAfterTimestamp();
            [objCached timestamp] = cm.loadData(name, param);
            if timestamp < timestampRef
                error('Cache has expired on %s', name);
            end

            debug('Cache hit on %s\n', name);

            % call postLoadOnCache function in case subclass has overridden it 
            % we pass along the pre-cache version of obj in case useful.
            objCached = objCached.postLoadFromCache(param, timestamp, obj);

            % when loading a handle class, we must manually transfer
            % all properties to current class (objCached -> obj) because
            % existing handles will reference the old object. We defer
            % to .transferToHandle to do this copying. This method should be
            % overwritten if any special cases arise
            if isa(obj, 'handle')
                objCached.transferToHandle(obj);
            else
                % value classes we handle with a simple assignment 
                obj = objCached;
            end
        end
    end

end
