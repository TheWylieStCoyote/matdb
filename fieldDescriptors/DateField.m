classdef DateField < DataFieldDescriptor

    properties(Dependent)
        matrix % returned as a matrix if true, returned as cell array if false
    end

    properties
        dateFormat % used mainly for DataFieldType.Date
    end

    properties(Constant)
        standardDateFormat = 'yyyy-mm-dd';
        standardDisplayFormat = 'dd mmm yyyy';
    end

    methods
        function dfd = DateField(varargin)
            p = inputParser;
            p.addOptional('dateFormat', '', @ischar);
            p.parse(varargin{:});

            dfd.dateFormat = p.Results.dateFormat;
        end

        function matrix = get.matrix(dfd)
            matrix = false;
        end

        % return a string representation of this field's data type
        function str = describe(dfd)
            if ~isempty(dfd.dateFormat)
                format = [' ' dfd.dateFormat];
            else
                format = '';
            end
            str = sprintf('DateField%s', format);
        end

        % converts DataFieldType.DateField values to a 1x6 datevec
        function vec = getAsDateVec(dfd, values)
            if isempty(dfd.dateFormat)
                vec = datevec(values, dfd.dateFormat);
            else
                vec = datevec(values);
            end
        end

        % converts DataFieldType.DateField values to a scalar datenum
        function num = getAsDateNum(dfd, values)
            if ~isempty(dfd.dateFormat)
                num = datenum(values, dfd.dateFormat);
            else
                num = datenum(values);
            end
        end

        function strCell = getAsDateStr(dfd, values, format)
            if nargin < 3
                format = DateField.standardDateFormat;
            end
            num = dfd.getAsDateNum(values);
            strCell = arrayfun(@(num) datestr(num, format), num, ...
                'UniformOutput', false);
        end

        % indicates whether this field should be displayed or not
        function tf = isDisplayable(dfd)
            tf = true;
        end

        % converts field values to a string
        function strCell = getAsStrings(dfd, values) 
            strCell = dfd.getAsDateStr(values, DateField.standardDisplayFormat);
        end

        function strCell = getAsFilenameStrings(dfd, values)
            strCell = dfd.getAsDateStr(values, 'yyyy-mm-dd');
        end
        
        % sorts the values in either ascending or descending order
        function sortIdx = sortValues(dfd, values, ascendingOrder)
            % on the basis of this field type, sort the values provided in values
            % (numeric or cell array) either in ascending or descending (inAscending = false)
            % order, maintaining the existing ordering if there is a tie
            %
            % sortIdx is the sort order, i.e. values(sortIdx) is in sorted order

            if isempty(values)
                sortIdx = [];
                return;
            end
            
            values = makecol(values);
            if ascendingOrder 
                sortMode = 'ascend';
            else
                sortMode = 'descend';
            end

            nums = dfd.getAsDateNum(values);
            [~, sortIdx] = sort(makecol(nums), 1, sortMode);
        end

        % converts field values to an appropriate format
        function convValues = convertValues(dfd, values) 
            % converts the set of field values in values to a format appropriate
            % for this DataFieldDescriptor.
           
            % convert these to string cell array
            if isempty(values) || iscell(values)
                [valid convValues] = isStringCell(values, 'convertVector', true);
                assert(valid, 'Cannot convert values into string cell array');

                % furthermore, convert the date to a standard date format
                nums = dfd.getAsDateNum(convValues);

            elseif isnumeric(values)
                nums = values;
            else
                error('Cannot convert values into DateField');
            end

            % since we only care about the date component, drop the decimal
            nums = floor(nums);

            convValues = arrayfun(@(num) datestr(num, ...
                DateField.standardDateFormat), nums, ...
                'UniformOutput', false);
            dfd.dateFormat = DateField.standardDateFormat;

            convValues = makecol(convValues);
        end

        % uniquifies field values
        function uniqueValues = uniqueValues(dfd, values)
            % finds the unique values within values according to the data type 
            % specified by this DataFieldDescriptor. Automatically removes empty
            % values and NaN values
           
            uniqueValues = unique(values);
        end

        % compares a list of field values to a reference value and returns -1, 0, 1 for each 
        function compareSign = compareValuesTo(dfd, values, ref)
            % given a list of values from this field, compare each to a reference value
            % ref, and return an array of -1, 0, 1 indicating <, ==, > the ref value

            nums = dfd.getAsDateNum(values);

            try
                refAsNum = datenum(ref);
            catch
                % no luck with auto datevec format, try using the 
                % same format as this field
                refAsNum = dfd.getAsDateNum(ref);
            end

            % drop the time component to only compare dates
            refAsNum = floor(refAsNum);

            compareSign = sign(nums - refAsNum);
        end

        function isEqual = valuesEqualTo(dfd, values, ref)
            % given a list of values from this field, compare each to a reference value
            % simply isEqual(i) indicates whether isequal(values(i), i)
            % this is similar to compareValuesTo except it is faster for some 
            % field types if you don't care about the sign of the comparison
                
            nums = dfd.getAsDateNum(values);

            try
                refAsNum = datenum(ref);
            catch
                % no luck with auto datevec format, try using the 
                % same format as this field
                refAsNum = dfd.getAsDateNum(ref);
            end

            % drop the time component to only compare dates
            refAsNum = floor(refAsNum);

            isEqual = nums == refAsNum;
        end
    end

    methods(Static) % Static utility methods
        function [tf dfd] = canDescribeValues(cellValues)
            [tf format num] = isDateStrCell(cellValues, 'allowMultipleFormats', false);

            if tf
                % all entries are date strings, are they even days with no time offset?
                if all(floor(num) == num)
                    % all values work with datevec --> date field
                    dfd = DateField();
                    dfd.dateFormat = format;
                else
                    % better suited for DateTimeField 
                    tf = false;
                    dfd = [];
                end
            else
                dfd = [];
            end
        end
    end
end
