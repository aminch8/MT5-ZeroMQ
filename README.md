# MT5-ZeroMQ
EA for Messaging Brokerage with ZeroMQ


# Installation:
Launch your Metatrader 5 client. Click on File > Open Data Folder. You will see a folder names MQL5.
Copy and paste JsonAPI.mq5 into Experts folder inside MQL5.
Copy "include" and paste it inside MQL5 folder.

Exit and Launch your Metatrader 5 client again. This time press F4 or click on Tools >  MetaQuotes Language Editor.

# Inside MetaQuotes Language Editor:
You should have the Navigator window open by default. in case you don't see this window, click on View > Navigator to enable it.
Now, you open Experts folder and double click on JsonAPI.mq5. The editor will open the file. You can view or edit the Expert Advisor here. Click on Build >  Compile.
Wait until compilation completes. Now you have succesfully compiled the EA. You can now use it inside your Metatrader 5 client.

# How to enable EA:
Click on Tools > Options. Click on Expert Advisors tab and enable Allow algorithmic trading and Allow DLL Imports.
Find Expert Advisors inside the Navigator tab. In case you don't see this windows, click on View > Navigator to enable it.
Open Expert Advisors, you will see JsonAPI in this section. Drag and drop it on a chart you want to Algo trade.
This should succesfully add the EA and enable it for you.
