classdef PValueField < ScalarField 

    methods(Static)
        function str = getPValueString(p)
            if p < 0.00001
                str = 'p << 0.001 *****';
            elseif p < 0.0001
                str = 'p < 0.0001 ****';
            elseif p < 0.001
                str = 'p < 0.001 ***';
            elseif p < 0.01
                str = 'p < 0.01 **';
            elseif p < 0.01
                str = 'p < 0.01 *';
            elseif p < 0.05 
                str = 'p < 0.05 *';
            else
                str = sprintf('p > 0.05 (%.2f)', p);
            end
        end
    end

    methods
        % return a string representation of this field's data type
        function str = describe(dfd)
            str = 'PValueField'; 
        end

        % converts field values to a string
        function strCell = getAsStrings(dfd, values) 
            strCell = arrayfun(@PValueField.getPValueString, values, 'UniformOutput', false);
        end
    end
end
