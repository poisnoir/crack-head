from spine import Namespace, Subscriber

from model import XboxController

print("hello world")
ns = Namespace("rime", "ppap")

sub = Subscriber(ns, "xbox-controller", XboxController)
while True:
    print(sub.get_data())
