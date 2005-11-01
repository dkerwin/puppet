module Puppet
    class State
        class PFileUID < Puppet::State
            require 'etc'
            @doc = "To whom the file should belong.  Argument can be user name or
                user ID."
            @name = :owner
            @event = :inode_changed

            def id2name(id)
                begin
                    user = Etc.getpwuid(id)
                rescue TypeError
                    return nil
                rescue ArgumentError
                    return nil
                end
                if user.uid == ""
                    return nil
                else
                    return user.name
                end
            end

            def name2id(value)
                begin
                    user = Etc.getpwnam(value)
                    if user.uid == ""
                        return nil
                    end
                    return user.uid
                rescue ArgumentError => detail
                    return nil
                end
            end

            # Determine if the user is valid, and if so, return the UID
            def validuser?(value)
                if value =~ /^\d+$/
                    value = value.to_i
                end

                if value.is_a?(Integer)
                    # verify the user is a valid user
                    if tmp = id2name(value)
                        return value
                    else
                        return false
                    end
                else
                    if tmp = name2id(value)
                        return tmp
                    else
                        return false
                    end
                end
            end

            # We want to print names, not numbers
            def is_to_s
                id2name(@is) || @is
            end

            def should_to_s
                case self.should
                when Integer
                    id2name(self.should) || self.should
                when String
                    self.should
                else
                    raise Puppet::DevError, "Invalid uid type %s(%s)" %
                        [self.should.class, self.should]
                end
            end

            def retrieve
                unless stat = @parent.stat(true)
                    @is = :notfound
                    return
                end

                self.is = stat.uid
            end

            # If we're not root, we can check the values but we cannot change them.
            # We can't really do any processing here, because users might
            # not exist yet.  FIXME There's still a bit of a problem here if
            # the user's UID changes at run time, but we're just going to have
            # to be okay with that for now, unfortunately.
            def shouldprocess(value)
                if tmp = self.validuser?(value)
                    return tmp
                else
                    return value
                end
            end

            def sync
                unless Process.uid == 0
                    unless defined? @@notifieduid
                        self.notice "Cannot manage ownership unless running as root"
                        #@parent.delete(self.name)
                        @@notifieduid = true
                    end
                    return nil
                end

                user = nil
                unless user = self.validuser?(self.should)
                    tmp = self.should
                    unless defined? @@usermissing
                        @@usermissing = {}
                    end

                    if @@usermissing.include?(tmp)
                        @@usermissing[tmp] += 1
                    else
                        self.notice "user %s does not exist" % tmp
                        @@usermissing[tmp] = 1
                        return nil
                    end
                end

                if @is == :notfound
                    @parent.stat(true)
                    self.retrieve
                    if @is == :notfound
                        self.info "File does not exist; cannot set owner"
                        return nil
                    end
                    if self.insync?
                        return nil
                    end
                    #self.debug "%s: after refresh, is '%s'" % [self.class.name,@is]
                end

                begin
                    File.chown(user, nil, @parent[:path])
                rescue => detail
                    raise Puppet::Error, "Failed to set owner to '%s': %s" %
                        [user, detail]
                end

                return :inode_changed
            end
        end
    end
end

# $Id$
